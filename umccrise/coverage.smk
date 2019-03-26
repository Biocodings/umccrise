## Cancer gene coverage

localrules: coverage, cacao, cacao_symlink


from ngs_utils.reference_data import get_key_genes_bed
from ngs_utils.file_utils import safe_symlink
from ngs_utils.file_utils import which


MIN_VD = 12     # minimal coverage to call a pure heterozygous variant
HIGH_VD = 100   # purity-normalized coverage above this is suspiciously high (lcr? repeat? CN?)

def _get_low_high_covs(phenotype, purple_file):
    p = _get_purity(phenotype, purple_file)
    return round(MIN_VD / p), round(HIGH_VD / p)

def _get_purity(phenotype, purple_file):
    """ Reading purity fro somatic sample from Purple output
        Assuming purity 100% for normal
    """
    purity = 1.0
    if phenotype == 'tumor':
        with open(purple_file) as f:
            header, values = f.read().split('\n')[:2]
        # #Purity  NormFactor  Score   DiploidProportion  Ploidy  Gender  Status  PolyclonalProportion  MinPurity  MaxPurity  MinPloidy  MaxPloidy  MinDiploidProportion  MaxDiploidProportion  Version  SomaticDeviation
        # 0.7200   1.0400      0.3027  0.8413             1.8611  FEMALE  NORMAL  0.0000                0.6600     0.7700     1.8508     1.8765     0.8241                0.8558                2.17     0.0006
        data = dict(zip(header.strip('#').split('\t'), values.split('\t')))
        purity = float(data['Purity'])
        # pure min cov  purity  min cov
        # 12            0.4     30
        # 12            0.5     24
        # 12            0.6     20
        # 12            0.7     17
        # 12            0.8     15
        # 12            0.9     13
        # 12            1.0     12
    return purity


# Looking at coverage for a limited set of (cancer) genes to assess overall reliability.
rule mosdepth:
    input:
        bam = lambda wc: getattr(batch_by_name[wc.batch], wc.phenotype).bam,
        bed = get_key_genes_bed(run.genome_build, coding_only=True),
        purple_purity = rules.purple_run.output.purity
    output:
        '{batch}/coverage/{batch}-{phenotype}.quantized.bed.gz',
        '{batch}/coverage/{batch}-{phenotype}.regions.bed.gz',
    params:
        prefix = '{batch}/coverage/{batch}-{phenotype}'
    run:
        low_cov, high_cov = _get_low_high_covs(wildcards.phenotype, input.purple_purity)
        cutoffs = f'0:1:{low_cov}:{high_cov}:'
        shell(
            'export MOSDEPTH_Q0=NO_COVERAGE && '
            'export MOSDEPTH_Q1=LOW_COVERAGE && '
            'export MOSDEPTH_Q2=CALLABLE && '
            'export MOSDEPTH_Q3=HIGH_COVERAGE && '
            f'mosdepth {params.prefix} -q {cutoffs} --no-per-base {input.bam} --by {input.bed}'
        )

# Also bringing in global coverage plots for review (tumor only, quick check for CNVs):
rule goleft_plots:
    input:
        bam = lambda wc: batch_by_name[wc.batch].tumor.bam,
    params:
        directory = '{batch}/coverage/{batch}-indexcov',
        xchr = 'X' if run.genome_build == 'GRCh37' else 'chrX'
    output:
        '{batch}/coverage/{batch}-indexcov/index.html'
    resources:
        mem_mb=2000
    shell:
        'goleft indexcov --directory {params.directory} {input.bam} --sex {params.xchr}'


pcgr_genome = 'grch38' if '38' in run.genome_build else 'grch37'

rule run_cacao_somatic:
    input:
        bam = lambda wc: getattr(batch_by_name[wc.batch], wc.phenotype).bam,
        purple_purity = rules.purple_run.output.purity
    output:
        report = '{batch}/coverage/cacao_{phenotype}/{batch}_' + pcgr_genome + '_coverage_cacao.html'
    params:
        cacao_data = hpc.get_ref_file(key='cacao_data'),
        output_dir = '{batch}/coverage/cacao_{phenotype}',
        docker_opt = '--no-docker' if not which('docker') else '',
        sample_id = '{batch}',
        mode = lambda wc: 'hereditary' if wc.phenotype == 'normal' else 'somatic',
        levels = lambda wc: 'germline' if wc.phenotype == 'normal' else 'somatic',
    resources:
        mem_mb=2000
    threads: threads_per_sample
    run:
        low_cov, high_cov = _get_low_high_covs(wildcards.phenotype, input.purple_purity)
        cutoffs = f'0:{low_cov}:{high_cov}'
        shell(
            conda_cmd.format('pcgr') +
            f'cacao_wflow.py {input.bam} {params.cacao_data} {params.output_dir} {pcgr_genome}' +
            f' {params.mode} {params.sample_id} {params.docker_opt} --threads {threads}'
            f' --callability_levels_{params.levels} {cutoffs}'
        )

rule cacao_symlink:
    input:
        rules.run_cacao_somatic.output.report
    output:
        '{batch}/{batch}-{phenotype}.cacao.html'
    run:
        safe_symlink(input[0], output[0], rel=True)

rule cacao:
    input:
        expand(rules.cacao_symlink.output[0],
               batch=batch_by_name.keys(),
               phenotype=['tumor', 'normal'])

rule coverage:
    input:
        (expand(rules.mosdepth.output[0],
                phenotype=['tumor', 'normal'],
                batch=batch_by_name.keys()) if which('mosdepth') else []),
        expand(rules.goleft_plots.output[0], batch=batch_by_name.keys()),
        expand(rules.cacao_symlink.output[0],
               batch=batch_by_name.keys(),
               phenotype=['tumor', 'normal'])
    output:
        temp(touch('log/coverage.done'))
