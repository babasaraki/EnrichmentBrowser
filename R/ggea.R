# GGEA, 16 June 2014
#
# UPDATE: 08 March 2016
#   - dealing with different kinds of networks

###
#
# GGEA - main function
#
# @param:   
#   se        ... SummarizedExperiment R object
#   gs      ... Gene sets
#   grn     ... Gene regulatory network
#               (3 cols: Regulator, Target, Effect)
#   alpha       ... Significance level. Defaults to 0.05.
#   beta        ... Significant log2 fold change level. Defaults to 1 (two-fold).
#   perm        ... Number of sample permutations. Defaults to 1000.
#
# @returns: the GGEA enrichment table
#
###         
.ggea <- function(se, gs, grn, 
    alpha=0.05, beta=1, perm=1000, gs.edges=c("&", "|"), cons.thresh=0.2)
{
    # map gs & grn to indices implied by fDat
    # due to performance issues, transforms character2integer
    # map gene.id -> index, e.g. "b0031" -> 10
    rcols <- sapply(c("FC.COL", "ADJP.COL"), configEBrowser)
    fDat <- as.matrix(rowData(se)[,rcols])
    fMap <- seq_len(nrow(fDat))
    names(fMap) <- rownames(fDat) 
        
    # transform gene sets & regulatory network
    grn <- .transformGRN(grn, fMap)
    gs <- .transformGS(gs, fMap)

    # restrict to gene sets with a minimal number of edges
    gs.grns <- lapply(gs, function(s) .queryGRN(s, grn, gs.edges))
    nr.rels <- lengths(gs.grns)
    ind <- which(nr.rels >= configEBrowser("GS.MIN.SIZE")) 
        #& (res.tbl[,"NR.RELS"] <= GS.MAX.SIZE)
    if(length(ind) == 0) stop("No gene set with minimal number of interactions")
    gs <- gs[ind]
    gs.grns <- gs.grns[ind]
    nr.rels <- nr.rels[ind]

    # score
    # compute consistency for all edges of the grn
    grn.cons <- .scoreGRN(fDat, grn, alpha, beta, cons.thresh) 

    # compute consistency scores for gene sets  
    gs.rels.cons <- lapply(gs.grns, function(gg) grn.cons[gg])
    thresh.rels <- lapply(gs.rels.cons, 
        function(gsc) which(gsc >= cons.thresh))   
    nr.thresh.rels <- lengths(thresh.rels)
    
    # restrict to gene sets with relations above consistency threshold
    ind <- which(nr.thresh.rels > 0)
    gs.cons <- vapply(ind, 
        function(i) sum(gs.rels.cons[[i]][thresh.rels[[i]]]),
        numeric(1))
    nr.rels <- nr.thresh.rels[ind]

    # result table
    res.tbl <- cbind(nr.rels, gs.cons)
    colnames(res.tbl) <- c("NR.RELS", "RAW.SCORE")
    rownames(res.tbl) <- names(gs)[ind]
    res.tbl <- cbind(res.tbl, res.tbl[,"RAW.SCORE"] / res.tbl[,"NR.RELS"])
    colnames(res.tbl)[ncol(res.tbl)] <- "NORM.SCORE" 

    # random permutation
    grn.cons <- grn.cons[grn.cons >= cons.thresh]
    if(perm > 0) 
        ps <- .permEdgesPval(res.tbl, grn.cons, perm)
    else ps <- .approxPval(res.tbl, grn.cons)
    res.tbl <- cbind(res.tbl, ps)
    colnames(res.tbl)[ncol(res.tbl)] <- configEBrowser("PVAL.COL") 
    return(res.tbl)
}

.scoreGRN <- function(fDat, grn, alpha, beta, cons.thresh)
{
    de <- .compDE(fDat, alpha=alpha, beta=beta)
    de.grn <- cbind(de[grn[,1]], de[grn[,2]])
    if(ncol(grn) > 2) de.grn <- cbind(de.grn, grn[,3])

    # compute consistency scores for grn
    grn.cons <- apply(de.grn, 1, .isConsistent)
    ind <- sum(grn.cons >= cons.thresh)
    if(length(ind) == 0) 
        stop("No edge of the GRN passes the consistency threshold")
    return(grn.cons)
}

##
# TRANSFORM & MAP
# 
# map GRN and GS IDs to index of respective IDs in ESET
##
.readGRN <- function(grn.file)
{
    first <- readLines(grn.file, n=1)
    nr.col <- length(unlist(strsplit(first, "\\s")))
    grn <- scan(grn.file, what="character", quiet=TRUE)
    grn <- matrix(grn, nrow=length(grn)/nr.col, ncol=nr.col, byrow=TRUE)
    return(unique(grn))
}

# map gene ids in grn to integer indices of rowData
# and make reg. type binary, i.e. ("+","-") -> (1,-1)
.transformGRN <- function(grn, fMap)
{
    # map regulators
    tfs <- fMap[grn[,1]]
    not.na.tfs <- !is.na(tfs)
    
    # map affected
    tgs <- fMap[grn[,2]]
    not.na.tgs <- !is.na(tgs)
    not.na <- not.na.tfs & not.na.tgs
        
    grn.mapped <- cbind(tfs, tgs)
    if(ncol(grn) > 2) 
    {
        # transform reg. type
        types <- ifelse(grn[,3]=="+", 1, -1)
        grn.mapped <- cbind(grn.mapped, types)
    }
    
    grn.mapped <- unique(grn.mapped[not.na,,drop=FALSE])
    ind <- do.call(order, as.data.frame(grn.mapped))
    grn.mapped <- grn.mapped[ind,,drop=FALSE]
    
    return(grn.mapped)
}

# map gene ids in gsets  to integer indices of rowData
.transformGS <- function(gs, fMap)
{
    gs.mapped <- lapply(gs, function(s){
                set <- fMap[s]
                set <- set[!is.na(set)]
                names(set) <- NULL  
                return(sort(unique(set)))
            })
    return(gs.mapped)
}

.queryGRN <- function(gs, grn, gs.edges=c("&", "|"), index=TRUE)
{
    gs.edges <- match.arg(gs.edges)
    ind <- which(do.call(gs.edges, list(grn[,1] %in% gs, grn[,2] %in% gs)))
    if(index) return(ind)
    else return(grn[ind, , drop=FALSE])
}


##
# DIFFERENTIAL EXPRESSION
#
# determine genewise diff. exp. by fuzzy fc and p
##

# fuzzification of a fc|p table to de values
# returns a three column table holding measures for 
# reduced, neutral & enhanced (in this order) diff. exp.
# for each fold change & p-value pair
.compDE <- function(fDat, alpha, beta, use.fc=TRUE)
{
    fcs <- fDat[,1]
    ps <- -log(fDat[,2], base=10)
    
    # fuzzy pvalue
    neg.log.alpha <- -log(alpha, base=10)
    inv.neg.log.alpha <- 1 / neg.log.alpha
    de <- vapply(ps, 
            function(p) 
                ifelse(p > neg.log.alpha, 1, p * inv.neg.log.alpha),
            numeric(1))
    
    if(use.fc)
    {
        # fuzzy fc
        abs.fcs <- abs(fcs)
        mapped.fcs <- vapply(abs.fcs, 
            function(fc) ifelse(fc > beta, 1, fc),
            numeric(1))
        de <- (mapped.fcs + de) / 2
    }
        
    de <- sign(fcs) * de
    return(de)
}


##
# CONSISTENCY
#
# compute edge consistencies and sum up for GGEA score
##

# determine consistency of a gene regulatory relation
# de(regulator)_de(target)_regulationType
.isConsistent <- function(grn.rel)
{
    act.cons <- mean(abs(grn.rel[1:2]))
    if(length(grn.rel) == 2) return(act.cons)	
    if(sum(sign(grn.rel[1:2])) == 0) act.cons <- -act.cons
    return( ifelse(grn.rel[3] == 1, act.cons, -act.cons) ) 
}


##
# 4 SIGNIFICANCE
#
# use sample permutations to determine statistical significance of GGEA score
##

# permutation of samples, de recomputation in each permutation 
.permSamplesPval <- function(se, gs.grns, grn, 
    obs.scores, perm, alpha, beta, cons.thresh)
{
    message(paste(perm, "permutations to do ..."))  
    
    # init
    GRP.COL <- configEBrowser("GRP.COL")
    grp <- colData(se)[,GRP.COL]
    nr.samples <- length(grp)
    count.larger <- vector("integer", length(obs.scores))
    
    # permute as often as reps are given
    rep.grid <- seq_len(perm)
    for(i in rep.grid)
    {
        if(i %% 100 == 0) message(paste(i,"permutations done ..."))
        # sample & permute
        grp.perm <- grp[sample(nr.samples)]
        colData(se)[,GRP.COL] <- grp.perm
        
        # recompute de measures fc and p
        se <- deAna(assay(se), grp.perm)
        fDat <- as.matrix(rowData(se)[,
            sapply(c("FC.COL", "ADJP.COL"), configEBrowser)])
        
        # recompute ggea scores
        grn.cons <- .scoreGRN(fDat, grn, alpha, beta, cons.thresh) 
        gs.rels.cons <- lapply(gs.grns, function(gg) grn.cons[gg])
        thresh.rels <- lapply(gs.rels.cons, 
                function(gsc) which(gsc >= cons.thresh))   
        nr.thresh.rels <- lengths(thresh.rels)
            
        # restrict to gene sets with relations above consistency threshold
        ind <- which(nr.thresh.rels > 0)
        perm.scores <- sapply(seq_along(gs.grns), 
            function(i) 
                ifelse(i %in% ind, 
                    sum(gs.rels.cons[[i]][thresh.rels[[i]]]), cons.thresh)) 
        
        #perm.scores <- tryCatch(recomp(), error = function(e){})
        #if(!is.null(perm.scores)) 
        count.larger <- count.larger + (perm.scores > obs.scores)
    }
    p <- count.larger / perm
    return(p)
}

# permutation of de
.permGenesPval <- function(fDat, grn, gs.grns, obs.scores, perm, alpha, beta)
{
    message(paste(perm, "permutations to do ..."))  
    # init
    count.larger <- vector("integer", length(obs.scores))
    
    # permute as often as reps are given
    rep.grid <- seq_len(perm)
    for(i in rep.grid)
    {
        if(i %% 100 == 0) message(paste(i,"permutations done ..."))
        # sample & permute
        fperm <- sample(nrow(fDat))
        fDat <- fDat[fperm,]        

        # recompute ggea scores
        grn.cons <- .scoreGRN(fDat, grn, alpha, beta)
        perm.scores <- vapply(gs.grns, 
            function(gg) sum(grn.cons[gg]), numeric(1))
        count.larger <- count.larger + (perm.scores > obs.scores)
    }
    p <- count.larger / perm
    return(p)
}

# sampling from background edge consistency distribution
.permEdgesPval <- function(res.tbl, grn.cons, perm)
{
        ps <- apply(res.tbl, 1, 
        function(x)
        {
            nr.rels <- as.integer(x["NR.RELS"])
            random.scores <- replicate(perm, sum(sample(grn.cons, nr.rels)))
            p <- (sum(random.scores > x["RAW.SCORE"]) + 1) / (perm + 1)
            return(p)
        })
    return(ps)
}

# approx by analytical edge consistency distribution (mixture of 2 gaussians)
.approxPval <- function(res.tbl, grn.cons)
{
    normalmixEM <- NULL
    isAvailable("mixtools", type="software")
    mixmdl <- normalmixEM(grn.cons)
    l <- mixmdl$lambda
    m <- mixmdl$mu
    s <- mixmdl$sigma

    ps <- apply(res.tbl, 1,
        function(x)
        {
            nr.rels <- sqrt(as.integer(x["NR.RELS"]))
            d <- sapply(1:2, function(i) 
                l[i] * pnorm(x["RAW.SCORE"], 
                mean=nr.rels * m[i], sd=nr.rels * s[i]))
            p <- 1 - sum(d)
            return(p)
        })
    return(ps)
}
