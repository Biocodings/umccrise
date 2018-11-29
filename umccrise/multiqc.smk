## IGV

localrules: multiqc, copy_logs


"""
#############################
### Prepare gold standard ###
#############################
cd /data/cephfs/punim0010/data/Results/Tothill-A5/2018-08-11
mkdir final.subset
for f in $(cat final/2018-08-11_2018-07-31T0005_Tothill-A5_WGS-merged/multiqc/list_files_final.txt | grep -v trimmed | grep -v target_info.yaml) ; do 
    mkdir -p final.subset/`dirname $f`
    cp final/$f final.subset/$f 
done
cd final.subset
ls | grep -v E201 | grep -v E199 | grep -v E194 | grep -v E190 | grep -v E202 | grep -v 2018-08-11_2018-07-31T0005_Tothill-A5_WGS-merged | xargs rm -rf
cd ..
cat final/2018-08-11_2018-07-31T0005_Tothill-A5_WGS-merged/multiqc/list_files_final.txt| grep -P "E201|E199|E194|E190|E202" > final.subset/list_files_final.txt

### Clean up ###
cd final.subset
# clean up qc/coverage
find . -name "*-indexcov.tsv" -delete
# clean up qc/fastqc
find . -name "fastqc_report.html" -delete
find . -name "Per_base_N_content.tsv" -delete
find . -name "Per_base_sequence_content.tsv" -delete
find . -name "Per_base_sequence_quality.tsv" -delete
find . -name "Per_sequence_GC_content.tsv" -delete
find . -name "Per_sequence_quality_scores.tsv" -delete
find . -name "Per_tile_sequence_quality.tsv" -delete
find . -name "Sequence_Length_Distribution.tsv" -delete
# clean up qc/qsignature - to repalce with project-level .ma file
rm -rf */qc/qsignature
# qc/peddy
find . -name "*.ped_check.rel-difference.csv" -delete
find . -name "*.html" -delete
"""


rule prep_multiqc_data:
    input:
        bcbio_mq_filelist = join(run.date_dir, 'multiqc/list_files_final.txt'),
        bcbio_mq_yaml     = join(run.date_dir, 'multiqc/multiqc_config.yaml'),
        bcbio_final_dir   = run.final_dir
    output:
        filelist        = 'work/{batch}/multiqc_data/multiqc_filelist.txt',
        conf_yaml       = 'work/{batch}/multiqc_data/umccr_multiqc_config.yaml',
        bcbio_conf_yaml = 'work/{batch}/multiqc_data/bcbio_multiqc_config.yaml'
    params:
        data_dir        = 'work/{batch}/multiqc_data'
    run:
        conf, additional_files = make_report_metadata(run, base_dirpath=abspath('.'))
        gold_standard_dir = join(package_path(), 'multiqc', 'gold_standard', 'final.subset')
        with open(join(gold_standard_dir, 'list_files_final.txt')) as f:
            for l in f:
                l = l.strip()
                additional_files.append(join(gold_standard_dir, l))
        multiqc_prep_data(
            bcbio_mq_filelist=input.bcbio_mq_filelist,
            bcbio_mq_yaml=input.bcbio_mq_yaml,
            bcbio_final_dir=input.bcbio_final_dir,
            new_mq_data_dir=params.data_dir,
            conf=conf,
            filelist_file=output.filelist,
            conf_yaml=output.conf_yaml,
            new_bcbio_mq_yaml=output.bcbio_conf_yaml,
            additional_files=additional_files,
            gold_standard_data=[]
        )


rule batch_multiqc:  # {}
    input:
        filelist        = 'work/{batch}/multiqc_data/multiqc_filelist.txt',
        conf_yaml       = 'work/{batch}/multiqc_data/umccr_multiqc_config.yaml',
        bcbio_conf_yaml = 'work/{batch}/multiqc_data/bcbio_multiqc_config.yaml'
    output:
        html_file       = '{batch}/{batch}-multiqc_report.html'
    run:
        ignore_samples=[s.name for s in run.samples if s.name not in
                [batch_by_name[wildcards.batch].tumor.name, batch_by_name[wildcards.batch].normal.name]]
        ignore_samples_re = '"' + '|'.join(ignore_samples) + '"'
        shell(f'multiqc -f -v -o . -l {input.filelist} -c {input.conf_yaml} -c {input.bcbio_conf_yaml}'
            ' --filename {output.html_file} --ignore-samples {ignore_samples_re}')

## Additional information
# TODO: link it to MultiQC
rule copy_logs:  # {}
    input:
        versions = join(run.date_dir, 'data_versions.csv'),
        programs = join(run.date_dir, 'programs.txt'),
        conf_dir = run.config_dir
    output:
        versions = 'log/' + run.project_name + '-data_versions.csv',
        programs = 'log/' + run.project_name + '-programs.txt',
        conf_dir = directory(join('log/' + run.project_name + '-config'))
    shell:
        'cp -r {input.versions} {output.versions} && ' \
        'cp -r {input.programs} {output.programs} && ' \
        'cp -r {input.conf_dir} {output.conf_dir}'


rule multiqc:
    input:
        expand(rules.batch_multiqc.output, batch=batch_by_name.keys()),
        rules.copy_logs.output,
    output:
        temp(touch('log/multiqc.done'))
