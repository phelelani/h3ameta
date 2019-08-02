#!/usr/bin/env nextflow

Channel.fromPath(params.inp_metaphlan).into { sequencing_data; report_in_data_ch }

mpa_db = file(params.mpa)


process MetaPhlAn2 {
   cpus 2
   time '4h'
   memory '4GB'
   input:
      file (infile) from sequencing_data
   output: 
      file "$out" into (bowtie_out_ch,metaphl_tables_ch)
   publishDir "${params.out_metaphlan}", mode: 'copy', overwrite: true
   script:
       out="${infile.baseName}_MetaPhlAn2_microbes_list.tsv"
       """ 
       #!/usr/bin/env bash
	metaphlan2.py --input_type fastq --mpa_pkl ${mpa_db}/mpa_v20_m200.pkl \
		      --bowtie2db ${mpa_db}/mpa_v20_m200 \
		      --bowtie2out ${infile.baseName}_bt2out.txt \
		      --nproc ${task.cpus} $infile\
			> $out
       """
}



process mergeTables {
  
  input:
    file (table) from bowtie_out_ch.toList()
  output:
    file (out) into (cluster_ch, report_merged_abundance_ch)
  publishDir "${params.out_metaphlan}", mode: 'copy', overwrite: true
  script:
    out = "merged_abundance_table.tsv"
   """
     merge_metaphlan_tables.py $table > $out
   """
}


process heatMap {
  input:
     file(abundance) from cluster_ch
  publishDir "${params.out_metaphlan}", mode: 'copy', overwrite: false
  output:
     file(heatmap) into heatmap_ch
  publishDir "${params.out_metaphlan}", mode: 'copy', overwrite: true
  script:
    heatmap = "abundance_heatmap.png"
    """
     metaphlan_hclust_heatmap.py -c bbcry --top 25 --minv 0.1 -s log \
              --in $abundance --out $heatmap
   """
}


process makeReport {
   publishDir "${params.out_metaphlan}", mode: 'copy', overwrite: false
   input:
      file (infile) from report_in_data_ch.toList()
      file (table) from report_merged_abundance_ch
      file (heatmap) from heatmap_ch
      file (metatabs) from metaphl_tables_ch.toList()
   output:
     file "report.txt" into metaphlan_report_ch
     cpus 1

   script:
   """
   #!/usr/bin/env bash
   echo "The input files were:" > report.txt
   for fn in ${infile}; do
       echo "  \$fn " >> report.txt
   done
   echo " " >> report.txt # blank like
   echo "The abundance table is $table:" >> report.txt
   echo "The heatmap file is $heatmap " >> report.txt 
   echo "#############" >> report.txt
   echo " " >> report.txt # blank like
   echo "The individual Metaphlan taxonomy files were:" >> report.txt
   for fn in ${metatabs}; do
       echo "  \$fn " >> report.txt
   done
   """

}
/*
#!/usr/bin/env nextflow
(c) University of the Witwatersrand, Johannesburg on behalf of the H3A Bioinformatics Network, 2019
Contributors:
   Eli Moss, Mushal Allam, Ansie Yssel, Heyam Mohammed, Scott Hazelhurst

and finally visualization with a custom bargraph script written in R, as well as Krona.
The accompanying nextflow.config file allows this workflow to be run on the Stanford SCG cluster with the
SLURM scheduler.
 ~/nextflow ../wits_workshop/nextflow/taxonomic_classification/taxonomic_classification.nf  --tax_level S -resume \
 -profile wits --in ../wits_workshop/nextflow/test_data/*.fq
*/

//The parameters below can all be overridden with --parametername on the commandline (e.g. --in or --dataset_table)



kraken_db     = file(params.db)
dataset_table = file(params.dataset_table)
annot_db      = file(params.annot_db)
strainSifter_config = file(params.strainSifter_config)





if (params.paired) {
    paired   = "--paired"
    in_srst2 = "--input_pe"
    Channel.fromFilePair(params.inp_kraken).into {data1; data2}
} else {
    paired = " "
    in_srst2 = "--input_se"
     Channel.fromPath(params.inp_kraken).map { file -> [file.baseName, name]}.into {data1; data2}
}


process kraken {
    cpus 2
    time '48h'
    memory '20GB' //20
    input:
       set val(name), file(sample_fq) from data1
       file kraken_db
    output: 
       file out into kraken_out 
    script:
      out = "${name}_kraken.tsv"
      """
      #!/usr/bin/env bash
      #note that the code below can be written in any language, so long as the interpreter is named
      #in the above shebang line.
      #also note: variables from this or higher scopes can be named inside strings with a dollar sign, as below.
      #when part of a larger name, as in the tsv output filename below, the variable must be enclosed with {}
      # the final $sample_fq names the input.
      kraken2 --db $kraken_db/ --threads $task.cpus $paired\
      --report $out \
      --quick --memory-mapping \
      $sample_fq
      """
}

process bracken {
   cpus 1
   time '48h'
   memory { 8.GB * task.attempt }
   input: 
      file f from kraken_out 
   output: 
      file "${f.baseName}_bracken.tsv" into (bracken_out1, bracken_out2) 
   publishDir '${params.out_kraken}', mode: 'copy', overwrite: true 
   script:
   """
	#!/usr/bin/env bash
	bracken -d $params.db -i $f \
	-o ${f.baseName}_bracken.tsv -r $params.readlen -l $params.tax_level \
   """
}



process krona {
    cpus 1
    time '1h'
    memory '1GB'
    input: 
      file k from bracken_out2
    output: 
      file "krona_${k}.html" into krona_out
    publishDir "${params.out_kraken}", mode: 'copy', overwrite: true
    """
    ktImportTaxonomy -m 3 -s 0 -q 0 -t 5 -i ${k} -o krona_${k}.html \
     -tax /global/taxonomy
    """
}

process collect_results {
   cpus 1
   time '1h'
   memory {2.GB * task.attempt } //dynamic resource allocation!
   publishDir "${params.out_kraken}", mode: 'copy', overwrite: true
   input:
       file data from dataset_table
       file f from bracken_out1.collect() 
   output: file 'class_long.tsv' into collect_results_out
   script:
   """
   collate_results.py $params.tax_level $data class_long.tsv $f
   """
}

process barplot {
   input: 
     file f from collect_results_out
   output: 
     file out_pdf into barplot_out
   publishDir "${params.out_kraken}", mode: 'copy', overwrite: true
   script:
      out_pdf = 'relative_abundance_barplot.pdf'
      """
      composition_barplot.R $f $out_pdf
      """
}

process srst2{
   cpus 1
   time '1h'
   memory '4GB'
   module 'samtools18'
   input: 
    set val(name), file(sample_fq) from data2 
    file annot_db
   output: 
     file outfname into srst2_annot_db_out
   publishDir "${params.out_kraken}", mode: 'copy', overwrite: true
   script:
     outfname = "*_results.txt"
     """
     #!/usr/bin/env bash
     srst2 ${in_srst2} $sample_fq --output ${name}_srst2 --gene_db $annot_db
     """   
}

process StrainSifter {
   cpus 1
   time '96h'
   label 'bigmem'
   input:             
       file strainSifter_config
   output: 
      file pdf  into StrainSifter_out
   publishDir "${params.out_kraken}", mode: 'copy', overwrite: true
   script:
      pdf = "nature.tree.pdf"
      """
      echo Need to handle this >  $pdf
      """
}
