#!/usr/bin/env nextflow
/*
========================================================================================
                         nf-core/nanoclust
========================================================================================
 nf-core/nanoclust Analysis Pipeline.
 #### Homepage / Documentation
 https://github.com/nf-core/nanoclust
----------------------------------------------------------------------------------------
*/
log.info nfcoreHeader()
def helpMessage() {
    
    log.info"""

    Usage:

    The typical command for running the pipeline is as follows:

    nextflow run nf-core/nanoclust --reads 'reads.fastq' --db "path/to/db" --tax "path/to/taxdb" -profile conda

    Mandatory arguments:
      --reads                       Path to input data (must be surrounded with quotes)
      -profile                      Configuration profile to use. Can use multiple (comma separated)
                                    Available: conda, docker, singularity, awsbatch, test and more.

    UMAP and HDBSCAN clustering parameters:
      --umap_set_size               Number of reads used to perform the UMAP+HDBSCAN clustering (100000)
      --cluster_sel_epsilon         Minimun distance to separate clusters. (0.5)
      --min_cluster_size            Minimum number of reads to call a independent cluster (100)
      --min_read_length             Minimum number of base pair in sequence reads (1400)
      --max_read_length             Maximum number of base pair in sequence reads (1700)
      --avg_amplicon_size               Average size for the sequenced amplicon (ie: 1.5k for 16S/1.8k for 18S)


    Other options:
      --demultiplex                 Set this parameter if you file is a pooled sample
      --demultiplex_porechop        Same as --demultiplex but uses Porechop for the task
      --kit                         (Only with --demultiplex) Barcoding kit (RAB204) {Auto,PBC096,RBK004,NBD104/NBD114,PBK004/LWB001,RBK001,RAB204,VMK001,PBC001,NBD114,NBD103/NBD104,DUAL,RPB004/RLB001}
      --umap_set_size               Number of reads used to perform the UMAP+HDBSCAN clustering (100000)
      --cluster_sel_epsilon         Minimun distance to separate clusters. (0.5)
      --min_cluster_size            Minimum number of reads to call a independent cluster (100)
      --polishing_reads             Number of reads used for polishing (100)
      --db                          Path to local BLAST database. If not specified, search will be done againts NCBI 16S Microbial
      --tax                         Path to taxdb database which contains the names for the --db entries
      --outdir                      The output directory where the results will be saved
      --email                       Set this parameter to your e-mail address to get a summary e-mail with details of the run sent to you when the workflow exits
      --email_on_fail               Same as --email, except only send mail if the workflow is not successful
      --maxMultiqcEmailFileSize     Theshold size for MultiQC report to be attached in notification email. If file generated by pipeline exceeds the threshold, it will not be attached (Default: 25MB)
      -name                         Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic.
    """.stripIndent()
}

// Show help message
if (params.help) {
    helpMessage()
    exit 0
}

/*
 * SET UP CONFIGURATION VARIABLES
 */

def racon_warnings = []

if(params.demultiplex) {
    Channel.fromPath(params.reads).set { multiplexed_reads }
}
else if(params.demultiplex_porechop){
    Channel.fromPath(params.reads).set { multiplexed_reads_porechop }
}
else{
    Channel.fromPath(params.reads).set { reads }
}

// Has the run name been specified by the user?
//  this has the bonus effect of catching both -name and --name
custom_runName = params.name
if (!(workflow.runName ==~ /[a-z]+_[a-z]+/)) {
  custom_runName = workflow.runName
}
// Stage config files
ch_multiqc_config = file(params.multiqc_config, checkIfExists: true)
ch_output_docs = file("$baseDir/docs/3pipeline_output.md", checkIfExists: true)

// Header log info
//log.info nfcoreHeader()

def summary = [:]
if (workflow.revision) summary['Pipeline Release'] = workflow.revision
summary['Run Name']         = custom_runName ?: workflow.runName
// TODO nf-core: Report custom parameters here
summary['Reads']            = params.reads
summary['Max Resources']    = "$params.max_memory memory, $params.max_cpus cpus, $params.max_time time per job"
if (workflow.containerEngine) summary['Container'] = "$workflow.containerEngine - $workflow.container"
summary['Output dir']       = params.outdir
summary['Launch dir']       = workflow.launchDir
summary['Working dir']      = workflow.workDir
summary['Script dir']       = workflow.projectDir
summary['User']             = workflow.userName

summary['Config Profile'] = workflow.profile
if (params.config_profile_description) summary['Config Description'] = params.config_profile_description
if (params.config_profile_contact)     summary['Config Contact']     = params.config_profile_contact
if (params.config_profile_url)         summary['Config URL']         = params.config_profile_url
if (params.email || params.email_on_fail) {
  summary['E-mail Address']    = params.email
  summary['E-mail on failure'] = params.email_on_fail
  summary['MultiQC maxsize']   = params.maxMultiqcEmailFileSize
}
log.info summary.collect { k,v -> "${k.padRight(18)}: $v" }.join("\n")
log.info "-\033[2m--------------------------------------------------\033[0m-"

// Check the hostnames against configured profiles
checkHostname()

def create_workflow_summary(summary) {
    def yaml_file = workDir.resolve('workflow_summary_mqc.yaml')
    yaml_file.text  = """
    id: 'nf-core-nanoclust-summary'
    description: " - this information is collected when the pipeline is started."
    section_name: 'nf-core/nanoclust Workflow Summary'
    section_href: 'https://github.com/nf-core/nanoclust'
    plot_type: 'html'
    data: |
        <dl class=\"dl-horizontal\">
${summary.collect { k,v -> "            <dt>$k</dt><dd><samp>${v ?: '<span style=\"color:#999999;\">N/A</a>'}</samp></dd>" }.join("\n")}
        </dl>
    """.stripIndent()

   return yaml_file
}

/*
 * Parse software version numbers
 */
/*
process get_software_versions {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy',
        saveAs: { filename ->
            if (filename.indexOf(".csv") > 0) filename
            else null
        }

    output:
    file 'software_versions_mqc.yaml' into software_versions_yaml
    file "software_versions.csv"

    script:
    // TODO nf-core: Get all tools to print their version number here
    """
    echo $workflow.manifest.version > v_pipeline.txt
    echo $workflow.nextflow.version > v_nextflow.txt
    """
} */

/*
 * STEP 1 - Quality control
 */

 good_reads = 0
 cluster_count = []

if(params.demultiplex) {
    process demultiplex {
     publishDir "${params.outdir}/demultiplexed_samples", mode: 'copy'

     input:
     file(reads) from multiplexed_reads

     output:
     file("barcode*.fastq") into reads mode flatten

     script:
     kit = params.kit
     """
     qcat -f $reads -k $kit --trim -t ${task.cpus} -b .
     """
 }
}

if(params.demultiplex_porechop){
    process demultiplex_porechop {
        input:
        file(reads) from multiplexed_reads_porechop

        output:
        file("BC*.fastq") into reads mode flatten

        script:
            """
            porechop -i "${reads}" -t 4 -b .
            """
    }
}

process QC {
    input:
    file(reads) from reads

    output:
    tuple env(barcode), file("*qced_reads_set.fastq") into reads_fastqc, qc_results 

    script:
    """
    barcode=${reads.baseName}
    fastp -i $reads -q 8 -l ${params.min_read_length} --length_limit ${params.max_read_length} -o \$barcode\\_qced_reads.fastq
    #perl prinseq-lite.pl -fastq $reads -out_good qced_reads -min_len 1400 -max_len 1700 -log qc_log -min_qual_mean 8
    head -n\$(( ${params.umap_set_size}*4 )) \$barcode\\_qced_reads.fastq > \$barcode\\_qced_reads_set.fastq
    """
}


process fastqc {
    publishDir "${params.outdir}/fastqc_rawdata", mode: 'copy',
    saveAs: {filename -> filename.indexOf(".zip") > 0 ? "zips/$filename" : "$filename"}

    input:
    set val(name), file(reads) from reads_fastqc

    output:
    file "*_fastqc.{zip,html}" into fastqc_results

    script:
    """
    fastqc -q $reads
    """
}
if(params.multiqc){
    process multiqc {
        publishDir "${params.outdir}/MultiQC", mode: 'copy'

        input:
        file ('fastqc/*') from fastqc_results.collect().ifEmpty([])
        
        output:
        file "*multiqc_report.html"
        file "*_data"

        script:
        """
        multiqc . 
        """
    }
}

 process kmer_freqs {
     memory { 7.GB * task.attempt }
     time { 1.hour * task.attempt }
     errorStrategy { task.exitStatus in 137..140 ? 'retry' : 'terminate' }
     maxRetries 3

     input:
     tuple val(barcode), file(qced_reads) from qc_results

     output:
     file "freqs.txt" into freqs
     tuple val(barcode), file(qced_reads) into freqs_qc_results

     script:   
     """
     kmer_freq.py -r $qced_reads > freqs.txt
     """

 }

 process read_clustering {
     time { 1.hour * task.attempt }
     errorStrategy { task.exitStatus in 137..140 ? 'retry' : 'terminate' }
     maxRetries 3

     publishDir "${params.outdir}/${barcode}/", mode: 'copy', pattern: 'hdbscan.output.*'

     input:
     file(kmer_freqs) from freqs
     tuple val(barcode), file(qced_reads) from freqs_qc_results

     output:
     tuple val(barcode), file('hdbscan.output.tsv'), file(qced_reads) into clustering_out
     file('*.png')

     script:
     template "umap_hdbscan.py"
 }

 process split_by_cluster {
     input:
     tuple val(barcode), file(clusters), file(qced_reads) from clustering_out

     output:
     tuple val(barcode), file('*[0-9]*.log'), file('*[0-9]*.fastq') into cluster_reads mode flatten

     script:
     """
     sed 's/\\srunid.*//g' $qced_reads > only_id_header_readfile.fastq
     CLUSTERS_CNT=\$(awk '(\$5 ~ /[0-9]/) {print \$5}' $clusters | sort -nr | uniq | head -n1)

     for ((i = 0 ; i <= \$CLUSTERS_CNT ; i++));
     do
        cluster_id=\$i
        awk -v cluster="\$cluster_id" '(\$5 == cluster) {print \$1}' $clusters > \$cluster_id\\_ids.txt
        seqtk subseq only_id_header_readfile.fastq \$cluster_id\\_ids.txt > \$cluster_id.fastq
        READ_COUNT=\$(( \$(awk '{print \$1/4}' <(wc -l \$cluster_id.fastq)) ))
        echo -n "\$cluster_id;\$READ_COUNT" > \$cluster_id.log
     done
     """
 }

 process read_correction {
     memory { 7.GB * task.attempt }
     time { 1.hour * task.attempt }
     errorStrategy { task.exitStatus in 137..140 ? 'retry' : 'terminate' }
     maxRetries 3

     input:
     tuple val(barcode), file(cluster_log), file(reads) from cluster_reads

     output:
      tuple val(barcode), val(cluster_id), file('*_racon_.log'), file('corrected_reads.correctedReads.fasta') into corrected_reads

     script:
     count=params.polishing_reads
     cluster_id=cluster_log.baseName
     """
     head -n\$(( $count*4 )) $reads > subset.fastq
     canu -correct -p corrected_reads -nanopore-raw subset.fastq genomeSize=${params.avg_amplicon_size} stopOnLowCoverage=1 minInputCoverage=2 minReadLength=500 minOverlapLength=200
     gunzip corrected_reads.correctedReads.fasta.gz
     READ_COUNT=\$(( \$(awk '{print \$1/2}' <(wc -l corrected_reads.correctedReads.fasta)) ))
     cat $cluster_log > ${cluster_id}_racon.log
     echo -n ";$count;\$READ_COUNT;" >> ${cluster_id}_racon.log && cp ${cluster_id}_racon.log ${cluster_id}_racon_.log
     """
 }

 process draft_selection {
     publishDir "${params.outdir}/${barcode}/cluster${cluster_id}", mode: 'copy', pattern: 'draft_read.fasta'
     errorStrategy 'retry'

     input:
     tuple val(barcode), val(cluster_id), file(cluster_log), file(reads) from corrected_reads

     output:
     tuple val(barcode), val(cluster_id), file('*_draft.log'), file('draft_read.fasta'), file(reads) into draft

     script:
     """
     split -l 2 $reads split_reads
     find split_reads* > read_list.txt

     fastANI --ql read_list.txt --rl read_list.txt -o fastani_output.ani -t 48 -k 16 --fragLen 160

     DRAFT=\$(awk 'NR>1{name[\$1] = \$1; arr[\$1] += \$3; count[\$1] += 1}  END{for (a in arr) {print arr[a] / count[a], name[a] }}' fastani_output.ani | sort -rg | cut -d " " -f2 | head -n1)
     cat \$DRAFT > draft_read.fasta
     ID=\$(head -n1 draft_read.fasta | sed 's/>//g')
     cat $cluster_log > ${cluster_id}_draft.log
     echo -n \$ID >> ${cluster_id}_draft.log
    """
 }

 process racon_pass {
     memory { 7.GB * task.attempt }
     time { 1.hour * task.attempt }
     errorStrategy { task.exitStatus in 137..140 ? 'retry' : 'terminate' }
     maxRetries 3

     input:
     tuple val(barcode), val(cluster_id), file(cluster_log), file(draft_read), file(corrected_reads) from draft

     output:
     tuple val(barcode), val(cluster_id), file(cluster_log), file('racon_consensus.fasta'), file(corrected_reads), env(success) into racon_output

     script:
     """
     success=1
     minimap2 -ax map-ont --no-long-join -r100 -a $draft_read $corrected_reads -o aligned.sam
     if racon --quality-threshold=9 -w 250 $corrected_reads aligned.sam $draft_read > racon_consensus.fasta ; then
        success=1
     else
        success=0
        cat $draft_read > racon_consensus.fasta
     fi

     """
 }

 process medaka_pass {
     memory { 7.GB * task.attempt }
     time { 1.hour * task.attempt }
     errorStrategy { task.exitStatus in 137..140 ? 'retry' : 'terminate' }
     maxRetries 3

     publishDir "${params.outdir}/${barcode}/cluster${cluster_id}", mode: 'copy', pattern: 'consensus_medaka.fasta/consensus.fasta' 

     input:
     tuple val(barcode), val(cluster_id), file(cluster_log), file(draft), file(corrected_reads), val(success) from racon_output

     output:
     tuple val(barcode), val(cluster_id), file(cluster_log), file('consensus_medaka.fasta/consensus.fasta') into final_consensus

     script:
     if(success == "0"){
        log.warn """Sample $barcode : Racon correction for cluster $cluster_id failed due to not enough overlaps. Taking draft read as consensus"""
        racon_warnings.add("""Sample $barcode : Racon correction for cluster $cluster_id failed due to not enough overlaps. Taking draft read as consensus""")
     }
     """
     if medaka_consensus -i $corrected_reads -d $draft -o consensus_medaka.fasta -t 4 -m r941_min_high_g303 ; then
        echo "Command succeeded"
     else
        cat $draft > consensus_medaka.fasta
     fi
     """

 }

 def resolve_blast_db_path (path) {
     if(path ==~ /^\/.*/)
         path
     else if(path ==~ /^\.\/.*/)
         "$projectDir/" + path
     else if(workflow.profile == 'conda' || workflow.profile == 'test,conda')
         "$baseDir/" + path
     else
         "/tmp/" + path
 }

 process consensus_classification {
     publishDir "${params.outdir}/${barcode}/cluster${cluster_id}", mode: 'copy', pattern: 'consensus_classification.csv'
     time '3m'
     errorStrategy { sleep(1000); return 'retry' }
     maxRetries 5

     input:
     tuple val(barcode), val(cluster_id), file(cluster_log), file(consensus) from final_consensus

     output:
     file('consensus_classification.csv')
     tuple val(barcode), file('*_blast.log') into classifications_ch

     script:
     db = resolve_blast_db_path(params.db)
     taxdb = resolve_blast_db_path(params.tax)

     if(!params.db)
        """
        blastn -query $consensus -db nr -remote -entrez_query "Bacteria [Organism]" -task blastn -dust no -outfmt "10 staxids sscinames evalue length score pident" -evalue 11 -max_hsps 50 -max_target_seqs 5 > consensus_classification.csv
        cat $cluster_log > ${cluster_id}_blast.log
        echo -n ";" >> ${cluster_id}_blast.log
        BLAST_OUT=\$(cut -d";" -f1,2,4,5 consensus_classification.csv | head -n1)
        echo \$BLAST_OUT >> ${cluster_id}_blast.log
        """

    else
        """
        export BLASTDB=
        export BLASTDB=\$BLASTDB:$taxdb
        blastn -query $consensus -db $db -task blastn -dust no -outfmt "10 sscinames staxids evalue length pident" -evalue 11 -max_hsps 50 -max_target_seqs 5 | sed 's/,/;/g' > consensus_classification.csv
        #DECIDE FINAL CLASSIFFICATION
        cat $cluster_log > ${cluster_id}_blast.log
        echo -n ";" >> ${cluster_id}_blast.log
        BLAST_OUT=\$(cut -d";" -f1,2,4,5 consensus_classification.csv | head -n1)
        echo \$BLAST_OUT >> ${cluster_id}_blast.log
        """
 }

 process join_results {
     publishDir "${params.outdir}/${barcode}", mode: 'copy'

     input:
     tuple val(barcode), file(logs) from classifications_ch.groupTuple()

     output:
     tuple val(barcode), file('*.nanoclust_out.txt') into output_table_ch

     script:
     """
     echo "id;reads_in_cluster;used_for_consensus;reads_after_corr;draft_id;sciname;taxid;length;per_ident" > ${barcode}.nanoclust_out.txt

     for i in $logs; do
        cat \$i >> ${barcode}.nanoclust_out.txt
     done
     """
     
 }

process get_abundances {
    publishDir "${params.outdir}/${barcode}", mode: 'copy'

    input:
    tuple val(barcode), file(table) from output_table_ch

    output:
    tuple val(barcode), file('*.csv') into abundance_table_ch mode flatten

    script:
    template "get_abundance.py"
}



process plot_abundances {
    publishDir "${params.outdir}/${barcode}", mode: 'copy'

    input:
    tuple val(barcode), file(table) from abundance_table_ch

    output:
    file("*.png")

    script:
    template "plot_abundances_pool.py"
}

process output_documentation {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy'

    input:
    file output_docs from ch_output_docs

    output:
    file "results_description.html"

    script:
    """
    markdown_to_html.py $output_docs -o results_description.html
    """
}

/*
 * Completion e-mail notification
 */
workflow.onComplete {

    // Set up the e-mail variables
    def subject = "[nf-core/nanoclust] Successful: $workflow.runName"
    if (!workflow.success) {
      subject = "[nf-core/nanoclust] FAILED: $workflow.runName"
    }
    def email_fields = [:]
    email_fields['version'] = workflow.manifest.version
    email_fields['runName'] = custom_runName ?: workflow.runName
    email_fields['success'] = workflow.success
    email_fields['dateComplete'] = workflow.complete
    email_fields['duration'] = workflow.duration
    email_fields['exitStatus'] = workflow.exitStatus
    email_fields['errorMessage'] = (workflow.errorMessage ?: 'None')
    email_fields['errorReport'] = (workflow.errorReport ?: 'None')
    email_fields['commandLine'] = workflow.commandLine
    email_fields['projectDir'] = workflow.projectDir
    email_fields['summary'] = summary
    email_fields['summary']['Date Started'] = workflow.start
    email_fields['summary']['Date Completed'] = workflow.complete
    email_fields['summary']['Pipeline script file path'] = workflow.scriptFile
    email_fields['summary']['Pipeline script hash ID'] = workflow.scriptId
    if (workflow.repository) email_fields['summary']['Pipeline repository Git URL'] = workflow.repository
    if (workflow.commitId) email_fields['summary']['Pipeline repository Git Commit'] = workflow.commitId
    if (workflow.revision) email_fields['summary']['Pipeline Git branch/tag'] = workflow.revision
    if (workflow.container) email_fields['summary']['Docker image'] = workflow.container
    email_fields['summary']['Nextflow Version'] = workflow.nextflow.version
    email_fields['summary']['Nextflow Build'] = workflow.nextflow.build
    email_fields['summary']['Nextflow Compile Timestamp'] = workflow.nextflow.timestamp

    // TODO nf-core: If not using MultiQC, strip out this code (including params.maxMultiqcEmailFileSize)
    // On success try attach the multiqc report
    def mqc_report = null
    try {
        if (workflow.success) {
            mqc_report = multiqc_report.getVal()
            if (mqc_report.getClass() == ArrayList) {
                log.warn "[nf-core/nanoclust] Found multiple reports from process 'multiqc', will use only one"
                mqc_report = mqc_report[0]
            }
        }
    } catch (all) {
        log.warn "[nf-core/nanoclust] Could not attach MultiQC report to summary email"
    }

    // Check if we are only sending emails on failure
    email_address = params.email
    if (!params.email && params.email_on_fail && !workflow.success) {
        email_address = params.email_on_fail
    }

    // Render the TXT template
    def engine = new groovy.text.GStringTemplateEngine()
    def tf = new File("$baseDir/assets/email_template.txt")
    def txt_template = engine.createTemplate(tf).make(email_fields)
    def email_txt = txt_template.toString()

    // Render the HTML template
    def hf = new File("$baseDir/assets/email_template.html")
    def html_template = engine.createTemplate(hf).make(email_fields)
    def email_html = html_template.toString()

    // Render the sendmail template
    def smail_fields = [ email: email_address, subject: subject, email_txt: email_txt, email_html: email_html, baseDir: "$baseDir", mqcFile: mqc_report, mqcMaxSize: params.maxMultiqcEmailFileSize.toBytes() ]
    def sf = new File("$baseDir/assets/sendmail_template.txt")
    def sendmail_template = engine.createTemplate(sf).make(smail_fields)
    def sendmail_html = sendmail_template.toString()

    // Send the HTML e-mail
    if (email_address) {
        try {
          if ( params.plaintext_email ){ throw GroovyException('Send plaintext e-mail, not HTML') }
          // Try to send HTML e-mail using sendmail
          [ 'sendmail', '-t' ].execute() << sendmail_html
          log.info "[nf-core/nanoclust] Sent summary e-mail to $email_address (sendmail)"
        } catch (all) {
          // Catch failures and try with plaintext
          [ 'mail', '-s', subject, email_address ].execute() << email_txt
          log.info "[nf-core/nanoclust] Sent summary e-mail to $email_address (mail)"
        }
    }

    // Write summary e-mail HTML to a file
    def output_d = new File( "${params.outdir}/pipeline_info/" )
    if (!output_d.exists()) {
      output_d.mkdirs()
    }
    def output_hf = new File( output_d, "pipeline_report.html" )
    output_hf.withWriter { w -> w << email_html }
    def output_tf = new File( output_d, "pipeline_report.txt" )
    output_tf.withWriter { w -> w << email_txt }

    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_red = params.monochrome_logs ? '' : "\033[0;31m";

    if (workflow.stats.ignoredCount > 0 && workflow.success) {
      log.info "${c_purple}Warning, pipeline completed, but with errored process(es) ${c_reset}"
      log.info "${c_red}Number of ignored errored process(es) : ${workflow.stats.ignoredCount} ${c_reset}"
      log.info "${c_green}Number of successfully ran process(es) : ${workflow.stats.succeedCount} ${c_reset}"
    }

    if (workflow.success) {
        log.info "${c_purple}[nf-core/nanoclust]${c_green} Pipeline completed successfully${c_reset}"
        if(!racon_warnings.isEmpty()){
            racon_warnings.each{log.warn "$it"}
        }
    } else {
        checkHostname()
        log.info "${c_purple}[nf-core/nanoclust]${c_red} Pipeline completed with errors${c_reset}"
    }

}


def nfcoreHeader(){
    // Log colors ANSI codes
    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_dim = params.monochrome_logs ? '' : "\033[2m";
    c_black = params.monochrome_logs ? '' : "\033[0;30m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_yellow = params.monochrome_logs ? '' : "\033[0;33m";
    c_blue = params.monochrome_logs ? '' : "\033[0;34m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_cyan = params.monochrome_logs ? '' : "\033[0;36m";
    c_white = params.monochrome_logs ? '' : "\033[0;37m";
    c_red = params.monochrome_logs ? '' : "\033[0;31m";

    return """   
    -${c_dim}--------------------------------------------------${c_reset}-
    ${c_green}      _   __                 ${c_red}    ________    __  _____________${c_reset}
    ${c_green}     / | / /___ _____  ____  ${c_red}   / ____/ /   / / / / ___/_  __/${c_reset}
    ${c_green}    /  |/ / __ `/ __ \\/ __ \\ ${c_red}  / /   / /   / / / /\\__ \\ / /   ${c_reset}
    ${c_green}   / /|  / /_/ / / / / /_/ / ${c_red} / /___/ /___/ /_/ /___/ // /    ${c_reset}
    ${c_green}  /_/ |_/\\__,_/_/ /_/\\____/  ${c_red} \\____/_____/\\____//____//_/     ${c_reset}

    ${c_purple}  NanoCLUST v${workflow.manifest.version}${c_reset}
    -${c_dim}--------------------------------------------------${c_reset}-
    """.stripIndent()
}

def checkHostname(){
    def c_reset = params.monochrome_logs ? '' : "\033[0m"
    def c_white = params.monochrome_logs ? '' : "\033[0;37m"
    def c_red = params.monochrome_logs ? '' : "\033[1;91m"
    def c_yellow_bold = params.monochrome_logs ? '' : "\033[1;93m"
    if (params.hostnames) {
        def hostname = "hostname".execute().text.trim()
        params.hostnames.each { prof, hnames ->
            hnames.each { hname ->
                if (hostname.contains(hname) && !workflow.profile.contains(prof)) {
                    log.error "====================================================\n" +
                            "  ${c_red}WARNING!${c_reset} You are running with `-profile $workflow.profile`\n" +
                            "  but your machine hostname is ${c_white}'$hostname'${c_reset}\n" +
                            "  ${c_yellow_bold}It's highly recommended that you use `-profile $prof${c_reset}`\n" +
                            "============================================================"
                }
            }
        }
    }
}
