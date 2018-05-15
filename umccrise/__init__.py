import os
import sys
from os.path import isfile, join, dirname, abspath
from ngs_utils.file_utils import verify_file, safe_mkdir
from ngs_utils import logger
import click
import subprocess
from python_utils.hpc import get_loc


import locale
try:
    if 'UTF-8' not in locale.getlocale(locale.LC_ALL):
        locale.setlocale(locale.LC_ALL, 'en_AU.UTF-8')
except TypeError:
    pass


def package_path():
    return dirname(abspath(__file__))


@click.command()
@click.argument('bcbio_project', type=click.Path(exists=True))
@click.argument('rule', nargs=-1)
@click.option('-o', 'output_dir', type=click.Path())
@click.option('-j', '--jobs', 'jobs', default=1, help='Max number of cores to use at single time (works both for local '
              'and cluster runs)')
@click.option('-s', '--sample', 'sample', help='Process only these samples or batches (comma-separated)')
@click.option('-e', '--exclude', 'exclude', help='Process only these samples or batches (comma-separated)')
@click.option('-b', '--batch', 'batch', help='Exclude these samples or batches (comma-separated)')
@click.option('-c', '--cluster-auto', 'cluster', is_flag=True, help='Submit jobs to cluster')
@click.option('--cluster', '--cluster-cmd', 'cluster_cmd', help='Submit jobs to cluster with the specified submission '
              'script command line template (use {threads} and {resources.mem_mb}) to subsitute with the appropriate'
              'parameters for each rule.')
@click.option('--unlock', is_flag=True)
@click.option('--rerun-incomplete', is_flag=True)
def main(bcbio_project, rule=list(), output_dir=None, jobs=None, sample=None, batch=None, exclude=None, unique_id=None, cluster=False, cluster_cmd=None, unlock=False, rerun_incomplete=False):

    output_dir = output_dir or 'umccrised'
    output_dir = abspath(output_dir)
    safe_mkdir(output_dir)

    logger.init(log_fpath_=join(output_dir, 'umccrise.log'), save_previous=True)

    rule = list(rule)

    bcbio_project = os.path.abspath(bcbio_project)

    conf = f'run_dir={bcbio_project}'

    if sample:
        conf += f' sample={sample}'
    if batch:
        conf += f' batch={batch}'
    if exclude:
        conf += f' exclude={exclude}'

    if 'pcgr_download' in rule or unique_id:
        conf += f' pcgr_download=yes'
    # if 'pcgr_download' in rule and not unique_id:
    #     sys.stderr.write(f'Error: when you run pcgr_download, provide the unique id with --uid option so umccrise can find the tarballs:\n')
    #     sys.stderr.write('\n')
    #     args = ' '.join(sys.argv)
    #     sys.stderr.write(f'    {args} --uid XXXXXX\n')
    #     sys.stderr.write('\n')
    #     sys.exit(1)
    if unique_id:
        conf += f' unique_id="{unique_id}"'

    cluster_param = ''
    if cluster or cluster_cmd:
        cluster_wrapper = join(package_path(), 'submit.py')
        if not cluster_cmd:
            loc = get_loc()
            cluster_cmd = loc.submit_job_cmd
            if not cluster_cmd:
                logger.critical(f'Automatic cluster submission is not supported for the machine "{loc.name}"')
        cluster_param = f' --cluster "{cluster_wrapper} \"{cluster_cmd}\""'

    cmd = (f'snakemake '
        f'{" ".join(rule)}'
        f' --snakefile {join(package_path(), "Snakefile")}'
        f' --printshellcmds'
        f' --directory {output_dir}'
        f' -j {jobs}'
        f'{" --rerun-incomplete " if rerun_incomplete or unlock else ""}' 
        f'{cluster_param}'
        f' --config {conf} '
    )

    if unlock:
        print('* Unlocking previous run... *')
        print(cmd + ' --unlock')
        subprocess.call(cmd + ' --unlock', shell=True)
        print('* Now rerunning *')

    print(cmd)
    exit_code = subprocess.call(cmd, shell=True)
    if exit_code != 0:
        sys.stderr.write('--------\n')
        sys.stderr.write(f'Error running Umccrise: snakemake returned a non-zero status.\n')
        sys.exit(exit_code)

    # Cleanup
    work_dir = join(output_dir, 'work')
    # if isdir(work_dir):
    #     shutils.rmtree(work_dir)


def get_sig_rmd_file():
    """ Returns path to sig.Rmd file - R-markdown source for mutational signature analysys.
        The file must be located at the same directory as the Snakefile and the patient_analysis module.
    """
    return verify_file(join(package_path(), 'sig.Rmd'))

def get_signatures_probabilities():
    return verify_file(join(package_path(), 'rmd_files', 'signatures_probabilities.txt'))

def get_suppressors():
    return verify_file(join(package_path(), 'rmd_files', 'suppressors.txt'))

def get_cancer_genes_ensg():
    return verify_file(join(package_path(), 'cancer_genes_ENSG.txt'))
