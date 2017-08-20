#' @title Refine Peaks with GC Effects
#'
#' @description
#' This function refines the ranks (i.e. significance/pvalue) of
#' pre-determined peaks by potential GC effects. These peaks can be
#' obtained from other peak callers, e.g. MACS or SPP.
#'
#' @param coverage A list object returned by function \code{read5endCoverage}.
#'
#' @param gcbias A list object returned by function \code{gcEffects}.
#'
#' @param bdwidth A non-negative integer vector with two elements
#' specifying ChIP-seq binding width and peak detection half window size.
#' Usually generated by function \code{bindWidth}. A bad estimation of
#' bdwidth results no meaning of downstream analysis. The values
#' need to be the same as it is when calculating \code{gcbias}.
#'
#' @param peaks A GRanges object specifying the peaks to be refined.
#' A flexible set of peaks are preferred to reduce potential false
#' negative, meaning both significant (e.g. p<=0.05) and non-significant
#' (e.g. p>0.05) peaks are preferred to be included. If the total
#' number of peaks is not too big, a reasonable set of peaks include
#' all those with p-value/FDR less than 0.99 by other peak callers.
#'
#' @param flank A non-negative integer specifying the flanking width of
#' ChIP-seq binding. This parameter provides the flexibility that reads
#' appear in flankings by decreased probabilities as increased distance
#' from binding region. This paramter helps to define effective GC
#' content calculation. Default is NULL, which means this paramater will
#' be calculated from \code{bdwidth}. However, if customized numbers
#' provided, there won't be recalucation for this parameter; instead, the
#' 2nd elements of \code{bdwidth} will be recalculated based on \code{flank}.
#' The value needs to be the same as it is when calculating \code{gcbias}.
#'
#' @param permute A non-negative integer specifying times of permutation to
#' be performed. Default is 5. When whole large genome is used, such as
#' human genome, 5 times of permutation could be enough.
#'
#' @param genome A \link[BSgenome]{BSgenome} object containing the sequences
#' of the reference genome that was used to align the reads, or the name of
#' this reference genome specified in a way that is accepted by the
#' \code{\link[BSgenome]{getBSgenome}} function defined in the \pkg{BSgenome}
#' software package. In that case the corresponding BSgenome data package
#' needs to be already installed (see \code{?\link[BSgenome]{getBSgenome}} in
#' the \pkg{BSgenome} package for the details). The value needs to be the same
#' as it is when calculating \code{gcbias}.
#'
#' @param gctype A character vector specifying choice of method to calculate
#' effective GC content. Default \code{ladder} is based on uniformed fragment
#' distribution. A more smoother method based on tricube assumption is also
#' allowed. However, tricube should be not used if estimated peak half size
#' is 3 times or more larger than estimated bind width. The value
#' needs to be the same as it is when calculating \code{gcbias}.
#'
#' @return A GRanges object the same as \code{peaks} with two additional
#' meta columns:
#' \item{newes}{Refined enrichment scores.}
#' \item{newpv}{Refined pvalues.}
#'
#' @import S4Vectors
#' @import IRanges
#' @import GenomicRanges
#' @import Biostrings
#' @importFrom BSgenome getBSgenome
#' @importFrom BSgenome getSeq
#' @importFrom methods as
#'
#' @export
#' @examples
#' bam <- system.file("extdata", "chipseq.bam", package="gcapc")
#' cov <- read5endCoverage(bam)
#' bdw <- bindWidth(cov)
#' gcb <- gcEffects(cov, bdw, sampling = c(0.15,1))
#' peaks <- gcapcPeaks(cov, gcb, bdw)
#' refinePeaks(cov, gcb, bdw, peaks)

refinePeaks <- function(coverage,gcbias,bdwidth,peaks,flank=NULL,
                        permute=5L,genome="hg19",
                        gctype=c("ladder","tricube")){
    genome <- getBSgenome(genome)
    gctype <- match.arg(gctype)
    bdw <- bdwidth[1]
    halfbdw <- floor(bdw/2)
    if(is.null(flank)){
        pdwh <- bdwidth[2]
        flank <- pdwh-bdw+halfbdw
    }else{
        pdwh <- flank+bdw-halfbdw
    }
    if(gctype=="ladder"){
      weight <- c(seq_len(flank),rep(flank+1,bdw),rev(seq_len(flank)))
      weight <- weight/sum(weight)
    }else if(gctype=="tricube"){
      w <- flank+halfbdw
      weight <- (1-abs(seq(-w,w)/w)^3)^3
      weight <- weight/sum(weight)
    }
    peaks <- sort(shift(resize(peaks,width(peaks)+bdw),-halfbdw))
    cat("Starting to refine peaks.\n")
    startp <- start(peaks) - 3*halfbdw - 2*flank
    endp <- end(peaks) + 3*halfbdw + 2*flank
    idx <- endp <= seqlengths(genome)[as.character(seqnames(peaks))] &
        startp >= 1
    if(sum(!idx)>0) {
        cat(paste("remove",sum(!idx),
                              "peaks located at chromosome ends\n"))
        peaks <- peaks[idx]
    }
    ### extending regions
    cat("...... extending peaks\n")
    regionsrc <- shift(resize(peaks,width(peaks)+halfbdw*4+flank*2+1),
                              -halfbdw*2-flank)
    seqlevels(regionsrc,pruning.mode="coarse") <- names(coverage$fwd)
    regionsgc <- shift(resize(regionsrc,width(regionsrc)+halfbdw*2),-halfbdw)
    ### gc content
    cat("...... caculating GC content\n")
    nr <- shift(resize(regionsgc,width(regionsgc)+flank*2),-flank)
    seqs <- getSeq(genome,nr)
    gcpos <- startIndex(vmatchPattern("S", seqs, fixed="subject"))
    gcposb <- vector("integer",sum(as.numeric(width(nr))))
    gcposbi <- rep(seq_along(nr),times=width(nr))
    gcposbsp <- split(gcposb,gcposbi)
    for(i in seq_along(nr)){
        gcposbsp[[i]][gcpos[[i]]] <- 1L
    }
    gcposbsprle <- as(gcposbsp,"RleList")
    gcnuml <- width(regionsgc)-halfbdw*2
    gcnum <- vector('numeric',sum(as.numeric(gcnuml)))
    gcnumi <- rep(seq_along(nr),times=gcnuml)
    gc <- split(gcnum,gcnumi)
    for(i in seq_along(nr)){
        gc[[i]] <- round(runwtsum(gcposbsprle[[i]],k=length(weight),
                       wt=weight),3)
        if(i%%500 == 0) cat('.')
    }
    cat('\n')
    rm(regionsgc,nr,seqs,gcpos,gcposb,gcposbi,
        gcposbsp,gcposbsprle,gcnuml,gcnum,gcnumi)
    ### gc weight
    cat("...... caculating GC effect weights\n")
    gcwbase0 <- round(Rle(gcbias$mu0med1/gcbias$mu0),3)
    gcw <- RleList(lapply(gc,function(x) gcwbase0[x*1000+1])) # slow
    rm(gc,gcwbase0)
    ### reads count
    regionrcsp <- split(regionsrc,seqnames(regionsrc))
    rcfwd <- RleList(unlist(viewApply(Views(coverage$fwd,ranges(regionrcsp)),
                 runsum,k=pdwh)))
    rcrev <- RleList(unlist(viewApply(Views(coverage$rev,ranges(regionrcsp)),
                 runsum,k=pdwh)))
    ### enrichment score
    cat("...... estimating enrichment score\n")
    esl <- width(regionsrc)-halfbdw*2-flank*2
    ir1 <- IRangesList(start=IntegerList(as.list(rep(1,length(esl)))),
               end=IntegerList(as.list(esl)))
    ir2 <- IRangesList(start=IntegerList(as.list(rep(1+halfbdw+flank,
               length(esl)))),end=halfbdw+flank+IntegerList(as.list(esl)))
    ir3 <- IRangesList(start=IntegerList(as.list(rep(1+halfbdw*2+flank*2,
               length(esl)))),
               end=halfbdw*2+flank*2+IntegerList(as.list(esl)))
    rc1 <- rcfwd[ir1]
    rc2 <- rcfwd[ir2]
    rc3 <- rcrev[ir1]
    rc4 <- rcrev[ir2]
    gcw1 <- gcw[ir2]
    gcw2 <- gcw[ir3]
    gcw3 <- gcw[ir1]
    esrlt <- round(2*sqrt(rc1*rc4)*gcw1-rc3*gcw3-rc2*gcw2,3)
    names(esrlt) <- seq_along(regionsrc)
    rm(rcfwd,rcrev,gcw,rc1,rc2,rc3,rc4)
    ### permutation analysis
    cat("...... permutation analysis\n")
    perm <- table(c())
    for(p in seq_len(permute)){
        covfwdp <- coverage$fwd[ranges(regionrcsp)]
        covrevp <- coverage$rev[ranges(regionrcsp)]
        for(i in seq_along(coverage$fwd)){
            covfwdp[[i]] <- covfwdp[[i]][sample.int(length(covfwdp[[i]]))]
            covrevp[[i]] <- covrevp[[i]][sample.int(length(covrevp[[i]]))]
        }
        end <- cumsum(width(regionrcsp))
        start <- end-width(regionrcsp)+1
        regionrcspp <- IRangesList(start=start,end=end)
        rcfwdp <- RleList(unlist(viewApply(Views(covfwdp,regionrcspp),
                                         runsum,k=pdwh)))
        rcrevp <- RleList(unlist(viewApply(Views(covrevp,regionrcspp),
                                         runsum,k=pdwh)))
        rcp1 <- rcfwdp[ir1]
        rcp2 <- rcfwdp[ir2]
        rcp3 <- rcrevp[ir1]
        rcp4 <- rcrevp[ir2]
        accum <- table(unlist(round(2*sqrt(rcp1*rcp4)*gcw1-rcp3*gcw3-
                                    rcp2*gcw2,3),use.names=FALSE))
        n <- intersect(names(perm), names(accum))
        perm <- c(perm[!(names(perm) %in% n)],
                 accum[!(names(accum) %in% n)],
                 perm[n] + accum[n])
        cat('......... permutation',p,'\n')
    }
    perm <- perm[order(as.numeric(names(perm)))]
    pvs <- 1- cumsum(as.numeric(perm))/sum(as.numeric(perm))
    names(pvs) <- names(perm)
    perm <- Rle(as.numeric(names(perm)),perm)
    minpv <- 1/length(perm)
    rm(covfwdp,covrevp,start,end,regionrcspp,rcp1,rcp2,rcp3,rcp4,
        rcfwdp,rcrevp,gcw1,gcw2,gcw3,esl,regionrcsp,perm)
    ### refine peak pvalues
    cat('...... reporting new p-value \n')
    newes <- max(esrlt)
    pvsn <- as.numeric(names(pvs))
    pvsni <- sapply(newes,function(x) sum(pvsn<=x))
    pvsni[pvsni==0] <- NA
    newpv <- pvs[pvsni]
    newpv[newes<min(pvsn)] <- 1
    newpv[newpv==0] <- minpv
    mcols(peaks) <- data.frame(mcols(peaks),newes=newes,newpv=newpv)
    peaks <- shift(resize(peaks,width(peaks)-bdw),halfbdw)
    peaks
}
