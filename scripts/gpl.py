#!/usr/bin/env python
import glob
from os.path import isfile, join, dirname, abspath, basename, exists
import click
import subprocess

from ngs_utils.call_process import run_simple
from ngs_utils.file_utils import verify_file, safe_mkdir, splitext_plus
from ngs_utils import logger, conda_utils
from ngs_utils.logger import info, critical, err
from ngs_utils.utils import set_locale; set_locale()
from umccrise import package_path
from reference_data import api as refdata


@click.command()
@click.option('-o', 'output_dir', type=click.Path(), help='Output directory (will be created if does not exist)')
@click.option('-N', 'normal_bam', type=click.Path(exists=True), required=True, help='Normal BAM')
@click.option('-T', 'tumor_bam', type=click.Path(exists=True), required=True, help='Tumor BAM')
@click.option('-S', 'snv_vcf', type=click.Path(exists=True), help='Small variants VCF (e.g. strelka, ensemble)')
@click.option('-nn', 'normal_name', help='Normal sample name')
@click.option('-tn', 'tumor_name', help='Tumor sample name')
@click.option('-s', 'sample')
@click.option('-g', 'genome', default='GRCh37')
@click.option('--genomes-dir', 'genomes_dir', help='Path to umccrise genomes dir (alternative to --gridss-ref-dir)')
@click.option('--gridss-ref-dir', 'gridss_ref_dir', help='Path to gridss genomes dir (alternative to --genomes-dir)')
@click.option('--ref-fa', 'ref_fa', help='Path reference fasta (useful if you need to override the default in '
                                         '--gridss-ref-dir in case if your contigs don\'t match the one there')
@click.option('-j', '-t', '--threads', '--jobs', 'threads')
@click.option('-m', '--jvmheap', 'jvmheap')

def main(output_dir=None, normal_bam=None, tumor_bam=None, snv_vcf=None,
         normal_name=None, tumor_name=None, sample=None,
         genome=None, genomes_dir=None, gridss_ref_dir=None, ref_fa=None, threads=None,
         jvmheap=None):

    gridss_linx_dir = abspath(join(package_path(), '..', 'gridss-purple-linx'))
    gridss_scripts_dir = abspath(join(package_path(), '..', 'gridss/scripts'))

    normal_name = normal_name or splitext_plus(basename(normal_bam))[0]\
        .replace('-ready', '').replace('-sorted', '')
    tumor_name = tumor_name or splitext_plus(basename(tumor_bam))[0]\
        .replace('-ready', '').replace('-sorted', '')
    sample = sample or tumor_name

    output_dir = safe_mkdir(abspath(output_dir or 'gridss'))
    logger.init(log_fpath_=join(output_dir, 'gridss.log'), save_previous=True)
    output_vcf = join(output_dir, f'{sample}-gridss-purple-linx.vcf')

    assert genome == 'GRCh37', 'Only GRCh37 is supported for GRIDSS yet'

    if genomes_dir:
        refdata.find_genomes_dir(genomes_dir)
    if not gridss_ref_dir:
        gridss_ref_dir = refdata.get_ref_file(genome, 'gridss_purple_linx_dir')
    if not ref_fa:
        ref_fa = ref_fa.get_ref_file(genome, 'fa')

    hmf_env_path = conda_utils.secondary_conda_env('hmf')

    gridss_jar = glob.glob(join(hmf_env_path, 'share/gridss-*/gridss.jar'))[0]
    amber_jar  = glob.glob(join(hmf_env_path, 'share/hmftools-amber-*/amber.jar'))[0]
    cobalt_jar = glob.glob(join(hmf_env_path, 'share/hmftools-cobalt-*/cobalt.jar'))[0]
    purple_jar = glob.glob(join(hmf_env_path, 'share/hmftools-purple-*/purple.jar'))[0]
    linx_jar   = glob.glob(join(hmf_env_path, 'share/hmftools-linx-*/sv-linx.jar'))[0]

    cmd = f"""
PATH={hmf_env_path}/bin:$PATH \
THREADS={threads} \
GRIDSS_JAR={gridss_jar} \
AMBER_JAR={amber_jar} \
COBALT_JAR={cobalt_jar} \
PURPLE_JAR={purple_jar} \
LINX_JAR={linx_jar} \
bash -x {join(gridss_linx_dir, 'gridss-purple-linx.sh')} \
-n {normal_bam} \
-t {tumor_bam} \
-v {output_vcf} \
-s {sample} \
--normal_sample {normal_name} \
--tumour_sample {tumor_name} \
--snvvcf {snv_vcf} \
--ref_dir {gridss_ref_dir} \
--install_dir {gridss_scripts_dir} \
--reference {ref_fa} \
--output_dir {output_dir} \
{f"--jvmheap {jvmheap}" if jvmheap else ""}
""".strip()

    try:
        run_simple(cmd)
    except subprocess.SubprocessError:
        err('--------\n')
        err(f'Error running GRIDSS-PURPLE-LINX.\n')
        raise


if __name__ == '__main__':
    main()
