#!/usr/bin/env nextflow

/*
 * kpil
 *
 * KIR structural interpretation for long reads. Beta version.
 *
 * Predict a (possibly-amiguous) pair of haplotypes given the
 * presence/absence (PA) genotype from one individual and a collection
 * of PA reference haplotypes.
 *
 * Individually processes all ".fastq" files in /opt/kpi/raw/. 
 * Mount your local folder here.
 * 
 * Outputs 3 interpretation files for each fastq file in /opt/kpi/output/. 
 * Mount your local folder here.
 * Three files:
 *   1. genotype: PA call for each gene
 *   2. reads: PA call for each read (middle 50-500 bases of each gene)
 *   3. interp: haplotype pair prediction
 *
 * @author Dave Roe
 */

// things that may change per run
// here are the FASTQ files
fqNameSuffix = 'fastq'          // extension on the file name
fqDir = '/opt/kpi/raw/'  //todo?
resultDir = '/opt/kpi/output'

// things that probably won't change per run
fqPath = fqDir + '*.' + fqNameSuffix
probeFile = '/opt/kpi/input/locus-hap_probes_v2.txt'
haps = '/opt/kpi/input/all_haps_v3.txt'
unmappedInd = "unmapped" // add 'unmapped' meta locus

fqs1 = Channel.fromPath(fqPath).ifEmpty { error "cannot find any fastq files matching ${fqPath}" }.map { path -> tuple(sample(path), path) }
fqs2 = Channel.fromPath(fqPath).ifEmpty { error "cannot find any fastq files matching ${fqPath}" }.map { path -> tuple(sample(path), path) }

/*
 * fq2locusBin
 *
 * Given a FASTQ file, bin the reads into separate files based on probe markers.
 * 
 * eval "bbduk.sh in=KP420443_KP420444.bwa.read1_short.fastq outm=2DL5.bin1 literal=TTGAACCCTCCATCACAGGTCCTGG k=25 maskmiddle=f"
 * 
 * Output files have an extension of 'bin1'.
 * @todo change extension to 'bin2.fastq'
 * @todo Remove the zero-length .bin1 files?
 */
process fq2locusBin {
  publishDir = resultDir
  input:
    set s, file(fq) from fqs1
  output:
    file{"*.bin1"} into bin1Fastqs

    """
    probeBinFastqs.groovy -i ${fq} -p ${probeFile} -s bin1
    """
} // fq2locusBin

/*
 * locusBin2ExtendedLocusBin
 * 
 * 1) Makes haplotype predictions from PA probes.
 * 2) For each gene, combine its bordering intergene reads into a single bin.
 *
 * Output files have an extension of 'bin1'.
 * @todo change extension to 'bin2.fastq'.
 */
process locusBin2ExtendedLocusBin {
  publishDir = resultDir
    // todo: add a set here?
  input:
    file(b1List) from bin1Fastqs.collect()
  output:
    file{"prediction.txt"} into predictionChannel
    file{"*.bin2"} into bin2Fastqs

    """
    outFile="prediction.txt"
    fileList=""
    ext="*bin1*"
    for bFile in $b1List; do
        if [ -s \$bFile ]; then
            if [[ \$bFile == \$ext ]]; then
                echo \$bFile
                if [ "\$fileList" == "" ]; then
                    :
                else
                    fileList+=","
                fi
                fileList+=\$bFile
            fi
        fi
    done
    echo \$fileList

    pa2Haps.groovy -h ${haps} -q \$fileList -o \$outFile
    binLoci.groovy -h ${haps} -q \$fileList -p \$outFile
    """
} // locusBin2ExtendedLocusBin

/* 
 * mergeAndAssemble
 *
 * For each of the two predicted haplotypes, use Canu to assemble 
 * each evenly-positioned locus (*.bin2) and its odd neighbors. 
 * Repeat until entire haplotypes are assembled.
 * 
 */
process mergeAndAssemble {
    publishDir resultDir, mode: 'copy', overwrite: 'true'
  input:
    file(prediction) from predictionChannel
    file(fqs) from bin2Fastqs
  output:
    file{"hap[12].fasta"} into finalAssembly

    """
    mergeAndAssemble.groovy -p ${prediction}
    """
} // mergeAndAssembleb

/* 
 * unitigs2Final
 *
 * Second, final, level Canu assembly.
 *
 *
process unitigs2Final {
    publishDir resultDir, mode: 'copy', overwrite: 'true'  //testing(todo)
  input:
    file(b3List) from unitigFastqs.collect()
  output:
    file{"assembly/*.fasta"} into assembly
//put bak(todo)    file{"assembly/*.unitigs.fasta"} into assembly

    """
    fname='all_bin3.fasta'
    name_intervening='intervening.fasta'
    for bFile in $b3List; do
        if [ -s \$bFile ]; then
            if [ "\$bFile" == *"3DP1"* ] || [ "\$bFile" == *"2DL4"* ]; then
                cat \$bFile >> \$name_intervening
            else
                cat \$bFile >> \$fname
            fi
        fi
    done
    # add unmapped reads to both bins
#todo    cat 'unmapped.unitigs.fasta' >> \$fname
#todo    cat 'unmapped.unitigs.fasta' >> \$name_intervening

    # assemble non-intervening regions
    title='assembly'
    echo canu maxMemory=8 -p \$title -d \$title genomeSize=200k -pacbio-corrected \$fname
    canu maxMemory=8 -p \$title -d \$title genomeSize=200k -pacbio-corrected \$fname

    # assemble intervening region
    title='assembly_intervening'
    echo canu maxMemory=8 -p \$title -d \$title genomeSize=15k -pacbio-corrected \$name_intervening
    canu maxMemory=8 -p \$title -d \$title genomeSize=15k -pacbio-corrected \$name_intervening
    """
} // unitigs2Final
*/

// get the per-sample name
def sample(Path path) {
  def name = path.getFileName().toString()
  int start = Math.max(0, name.lastIndexOf('/'))
  int end = name.indexOf(fqNameSuffix)
  if ( end <= 0 ) {
    throw new Exception( "Expected file " + name + " to end in '" + fqNameSuffix + "'" );
  }
  end = end -1 // Remove the trailing '.'
  return name.substring(start, end)
} // sample

workflow.onComplete {
  println "DONE: ${ workflow.success ? 'OK' : 'FAILED' }"
}

workflow.onError {
  println "ERROR: ${workflow.errorReport.toString()}"
}
