# Umccrise workflow

Umccrise post-processess outputs of cancer variant calling analysis pipelines from either of 2 platforms: ([bcbio-nextgen](https://github.com/chapmanb/bcbio-nextgen) and Illumina Dragen, and generates reports helpful for researchers and curators at UMCCR. The minimal input for it is a tumor/normal variant calling workflow  containing at least a BAM files for a tumor sample and a BAM file for a normal sample, T/N somatic variant calls, and optionally germline variant calls from the normal sample, and structural somatic variant calls performed by Manta.

## SNPs and small indels

### Somatic

This part of the workflow filters and prioritizes somatic variant calls. The idea of filtering is to remove most of the artefacts and germline leakage, but at the same time to be permissive towards known clinically important sites even if the variants are low quality.

To outline the filtering routine, there are 3 basic steps:

1. Call candidate variants (2/3 mutect2/strelka2/vardict) with a cut-off AF>=1%.
2. Keep a candidate variant if either:
    1. AF>=10%, it's not in PoN and not common in gnomAD 
    2. The variant is potentially known. One of the following applies: PCGR TIER 1 or 2, IntOGen driver mutation, cancerhotspots.org hotspot, ClinVar pathogenic or uncertain (to include mixed evidence); COSMIC count >=10; TCGA pancancer count >=5; ICGC PCAWG count >= 3.
3. Additionally, we run SAGE on a list of hotspot sites (from CGI, CIViC, OncoKB - curated by HMF). The difference between 2.2 is that we are not restricted to the candidate variants from mutect2/strelka2/vardict, but rather to the hotspot sites.

In detail:

*Input*: for [bcbio](https://github.com/umccr/workflows/tree/master/bcbio), it's a somatic variant call output from a `variant2` tumor/normal (T/N) variant calling workflow. It can be either an "ensemble" somatic VCF `<batch>-ensemble-annotated.vcf.gz` (e.g. build from variants supported by at least 2 of 3 callers - in UMCCR, we use [Strelka](https://github.com/Illumina/strelka), [VarDict](https://github.com/AstraZeneca-NGS/VarDict), and [Mutect](https://software.broadinstitute.org/gatk/documentation/tooldocs/4.beta.4/org_broadinstitute_hellbender_tools_walkers_mutect_Mutect2.php)), or Strelka somatic VCF `<batch>-strelka2-annotated.vcf.gz` (in UMCCR, we process WGS FFPE samples with Strelka-only workflow to avoid performance issues with other callers). We also call variants at AF>1% (`min_allele_fraction: 1` setting in bcbio config), however that's not essential.

1. Extract passing calls (with `PASS` in FILTER)
2. Extract calls on main chromosomes (chr1-chr22, chrX, chrY)
3. Run [SAGE](https://github.com/hartwigmedical/hmftools/tree/master/sage) and add the result to the VCF. SAGE is a low-frequency variant caller with a high precision, created by Hartwig Medical Foundation. Instead of the whole genome, it targets only coding regions for inframe indels, and [known hotspot sites](https://raw.githubusercontent.com/umccr/workflows/master/genes/hotspots/hotspots.tsv) from the following list:
	*  [Cancer Genome Interpreter](https://www.cancergenomeinterpreter.org/home) 
	*  [CIViC](http://civic.genome.wustl.edu/) - Clinical interpretations of variants in cancer
	*  [OncoKB](https://oncokb.org/) - Precision Oncology Knowledge Base
4. Annotate the VCF against the reference sources:
	*  High-confidence regions from the Genome in a Bottle benchmark;
	*  [GnomAD](https://gnomad.broadinstitute.org) whole genome "common" variants (max population frequency > 1%);
	*  Low complexity regions (LCR):
    	*  Homopolymers, STRs, VNTRs and other repetitive sequences, [compiled from TRDB](https://github.com/ga4gh/benchmarking-tools/blob/master/resources/stratification-bed-files/LowComplexity/TRDB_processing.sh),
	    *  Regions compiled by Heng Li from 3 separate masks: low-complexity regions by mDUST and from UCSC repeatMasker plus flanking regions, structural mask (HWE+depth mask from 1000g plus flanking regions), and 75bp mappability mask.
	*  Low and high-GC regions (regions < 30% or > 65% GC content), [compiled by GA4GH](https://github.com/ga4gh/benchmarking-tools/tree/master/resources/stratification-bed-files/GCcontent)
	*  Bad promoter regions ([compiled by GA4GH](https://github.com/ga4gh/benchmarking-tools/tree/master/resources/stratification-bed-files/FunctionalTechnicallyDifficultRegions): "Anecdotal results suggested that many transcription start sites or first exons in the human genome tend to have poor coverage. By a systematic analysis of these regions we defined the 1,000 with the lowest relative coverage based on low coverage by an Illumina data set, which we term the 'bad promoters' list. The bad promoters are, like many exons, GC-rich, averaging 79% GC composition");
	*  [ENCODE blacklist](https://github.com/Boyle-Lab/Blacklist);
	*  Segmental duplication regions (UCSC);
	*  UMCCR [panel of normals](https://github.com/umccr/vcf_stuff/blob/master/vcf_stuff/panel_of_normals/story/panel_of_normals.md), build from tumor-only mutect2 calls from ~200 normal samples.
5. If after removing non-hotspot GnomAD variants there are still > 500k somatic variants left flag the sample as highly mutated (or FFPE) and limit all calls to to cancer genes only (to avoid downstream R performance problems).
6. Standardize the VCF fields: add new `INFO` fields `TUMOR_AF`, `NORMAL_AF`, `TUMOR_DP`, `NORMAL_DP`, `TUMOR_VD`, `NORMAL_VD` (for use with PCGR), and `AD FORMAT` field (for use with PURPLE).
7. Run [PCGR](https://github.com/sigven/pcgr) to annotate VCF against the external sources, and classify by tiers based on annotations and functional impact. At the end, this step adds `INFO` fields into the VCF: `TIER`, `SYMBOL`, `CONSEQUENCE`, `MUTATION_HOTSPOT`, `INTOGEN_DRIVER_MUT`, `TCGA_PANCANCER_COUNT`, `CLINVAR_CLNSIG`, `ICGC_PCAWG_HITS`, `COSMIC_CNT`. The list of external sources used at this step is:
	* [VEP](http://www.ensembl.org/info/docs/tools/vep/index.html) to infer the functional impact
	* TCGA and ICGC recurrent variants
	* [Open Targets Platform](https://targetvalidation.org/)
    * [ClinVar](http://www.ncbi.nlm.nih.gov/clinvar/) - Database of variants with clinical significance
    * [CancerMine](https://zenodo.org/record/2662509#.XM0xMdMzaL4) - Literature-derived database of tumor suppressor genes/proto-oncogenes
    * [DoCM](http://docm.genome.wustl.edu) - Database of curated mutations
    * [CBMDB](http://www.cancergenomeinterpreter.org/biomarkers) - Cancer Biomarkers database 
    * [DisGeNET](http://www.disgenet.org) - Database of gene-tumor type associations
    * [Cancer Hotspots](http://cancerhotspots.org) - Resource for statistically significant mutations in cancer
    * [dBNSFP](https://sites.google.com/site/jpopgen/dbNSFP) - Database of non-synonymous functional predictions
    * [UniProt/SwissProt KnowledgeBase](http://www.uniprot.org) - Resource on protein sequence and functional information
    * [Pfam](http://pfam.xfam.org) - Database of protein families and domains
    * [DGIdb](http://dgidb.genome.wustl.edu) - Database of targeted cancer drugs
    * [ChEMBL](https://www.ebi.ac.uk/chembl/) - Manually curated database of bioactive molecules
8. [Filter variants](https://github.com/umccr/vcf_stuff/blob/master/scripts/filter_somatic_vcf) to remove putative germline variants and artefacts, but make sure to keep known hotspots/actionable variants:
	*  Keep variants called by SAGE in known hotspots (CGI, CiViC, OncoKB) regardless of other evidence;
	*  Keep variants PCGR TIER 1 and 2 (strong and potential clinical significance, according to [ACMG](https://www.ncbi.nlm.nih.gov/pubmed/27993330) standard guidelines) regardless of other evidence;
	*  Keep all driver mutations ([Intogen](https://www.intogen.org/)); [mutation hotspots](http://cancerhotspots.org/]); [ClinVar](https://www.ncbi.nlm.nih.gov/clinvar/) pathogenic or uncertain (to include the mixed evidence); COSMIC count >=10; TCGA pancancer count >=5; ICGC PCAWG count >= 3 (all annotated by PCGR), regardless of other evidence;
	*  For all other variants, apply the following LCR, PoN, depth and AF filters. Remove variants for which one or more of the following conditions apply:
		* `AF`<10%,
		* Common variant in GnomAD (max `population AF`>=1%), add into the germline set (see below);
		* Present in >=5 samples of the Panel of Normal set;
		* InDel in a "bad promoter" regions (GA4GH: "Anecdotal results suggested that many transcription start sites or first exons in the human genome tend to have poor coverage. By a systematic analysis of these regions we defined the 1,000 with the lowest relative coverage based on low coverage by an Illumina data set, which we term the 'bad promoters' list. The bad promoters are, like many exons, GC-rich, averaging 79% GC composition);
		* Overlapping the [ENCODE blacklist](https://github.com/Boyle-Lab/Blacklist),
		* Variant depth `VD`<4;
		* Variant depth `VD`<6, and the variant overlaps a low complexity region (see step 4 above);
		* VarDict strand-biased variants (single strand support for ALT, while REF has both; or REF and ALT have opposite supporting strands), unless supported by all other callers.
9. Report passing variants using [PCGR](https://github.com/sigven/pcgr), classified by the ACMG tier system.


### Germline

The idea is to simply bring germline variants in cancer predisposition genes:

1. Take passing "ensemble" germline VCF from [bcbio](https://github.com/umccr/workflows/tree/master/bcbio). "Ensemble" has variants supported by at least 2 of 3 callers (we use strelka2, vardict, and GATK Haplotype Caller).
2. Add back variants from somatic calling filtered as common GnomAD.
3. Subset variants to a list of ~200 cancer predisposition genes, which is build by [CPSR](https://github.com/sigven/cpsr) from 3 curated sources: [TCGA](https://www.ncbi.nlm.nih.gov/pubmed/29625052) pan-cancer study, [COSMIC CGC](https://cancer.sanger.ac.uk/census), and [Norwegian Cancer Genomics Consortium](http://cancergenomics.no/).
4. Report variants using [CPSR](https://github.com/sigven/cpsr), which classifies variants in the context of cancer predisposition by overlapping with [ClinVar](https://www.ncbi.nlm.nih.gov/clinvar/) pathogenic and VUS variants and GnomAD rare variants. It also ranks variants according pathogenicity score by ACMG and cancer-specific criteria. When a variant is annotated as having multiple functional depending on a context of a gene and a trascript, a higher impact events are prioritized, and if all things equal, [APPRIS principal transcripts](http://appris.bioinfo.cnio.es/#/) are preferred. In any case, one event per variant is reported. Events are reported in 4 tiers according to their significance:
    * ClinVar variants: pre-classified variants according to a five-level tier scheme (Pathogenic to Benign):
    * Non-ClinVar variants: classified by CPSR according to a five-level tier scheme (Pathogenic to Benign)
    * Secondary findings (optional) - pathogenic ClinVar variants in the ACMG recommended list for reporting of incidental findings,
    * GWAS hits (optional) - variants overlapping with previously identified hits in genome-wide association studies (GWAS) of cancer phenotypes (i.e. low to moderate risk conferring alleles), using NHGRI-EBI Catalog of published genome-wide association studies as the underlying source. The unclassified non-ClinVar variants are assigned a pathogenicity level based on the aggregation of scores according to previously established ACMG criteria. The ACMG criteria includes cancer-specific criteria, as outlined and specified in several previous studies.

## Structural variants

The idea is to report gene fusions, exon deletions, high impact and LoF events in tumor suppressors, and prioritize events in cancer genes.

1. Start with the somatic SV VCF from [bcbio](https://github.com/umccr/workflows/tree/master/bcbio) called by [Manta](https://github.com/illumina/manta) SV caller. 
2. Refine SVs using Hartwig [break-point-inspector](https://bioconda.github.io/recipes/break-point-inspector/README.html), which locally re-assembles SV loci to get more accurate breakpoint positions and AF estimates.
3. Filter low-quality calls:
   * require split or paired reads support at least 5x,
   * for low frequency variants (<10% at both breakpoints), require read support 10x,
   * require paired reads support to be higher than split read support for BND events
4. Annotate variants impact using [SnpEff](http://snpeff.sourceforge.net/SnpEff_manual.html) according to the Ensembl gene model and [Sequence ontology](http://www.sequenceontology.org) terminology.
5. Subset annotations to [APPRIS principal transcripts](http://appris.bioinfo.cnio.es/#/), keeping one main isoform per gene.
6. Use variants as a guidance for PURPLE CNV calling (see below). PURPLE will adjust and recover breakpoints at copy number transitions, and adjust AF based on copy number, purity and ploidy.
7. Prioritize variants with [simple_sv_annotation](https://github.com/vladsaveliev/simple_sv_annotation) on a 4 tier system - 1 (high) - 2 (moderate) - 3 (low) - 4 (no interest):
    * exon loss
       * on cancer gene list (1)
       * other (2)
    * gene fusion
       * paired (hits two genes)
          * on list of known pairs (1) (curated by [HMF](https://resources.hartwigmedicalfoundation.nl))
          * one gene is a known promiscuous fusion gene (1) (curated by [HMF](https://resources.hartwigmedicalfoundation.nl))
          * on list of [FusionCatcher](https://github.com/ndaniel/fusioncatcher/blob/master/bin/generate_known.py) known pairs (2)
          * other:
             * one or two genes on cancer gene list (2)
             * neither gene on cancer gene list (3)
       * unpaired (hits one gene)
           * on cancer gene list (2)
           * others (3)
    * upstream or downstream (a specific type of fusion, e.g. one gene is got into control of another gene's promoter and get over-expressed (oncogene) or underexpressed (tsgene))
       * on cancer gene list genes (2)
    * LoF or HIGH impact in a tumor suppressor
       * on cancer gene list (2)
       * other TS gene (3)
    * other (4)    
8. If the number of events is over 10k (e.g. FFPE), keep only tiers 1-2-3
9. For tiers 3-4:
    a. require split or paired reads support of at least 5x,
    b. for low frequency variants (<10% at both breakpoints), require read support of at least 10x,
    c. require paired reads support to be higher than split read support for BND events
10. Unless FFPE, feed the variants into PURPLE to recover SVs from copy number transitions
11. Report tiered variants in the UMCCR cancer report.


## Somatic CNV

The idea is to report significant CNV changes in key cancer genes and disruptions in tumor suppressors. And also calculate sample purity and ploidy profile.

We almost entirely rely on Hartwig's [PURPLE](https://github.com/hartwigmedical/hmftools/tree/master/purity-ploidy-estimator) workflow in this step. The PURPLE pipeline outlines as follows:

* Calculate B-allele frequencies (BAF) using AMBER subworkflow,
* Calculate read depth ratios using COBALT subworkflow,
* Perform segmentation (uses structural variant breakpoints for better guidance),
* Estimate the purity and copy number profile (uses somatic variants for better fitting), 
* Plot a circos plot that visualizes the CN/ploidy profile, as well as somatic variants, SVs, and BAFs,
* Rescue structural variants in copy number transitions and filter single breakends,
* Estimate overall tumor samples purity range,
* Determine gender, 
* Report QC status of the sample, that will fail if the structural variants do not correspond to CN transitions, and gender is inconsistently called from BAFs and from the coverage.

From the PURPLE output, we report in the cancer report:

* Circos plot
* Minimal and maximal copy numbers in key cancer genes, that indicate amplifications/deletions as well as CN transitions that should match SVs
* QC status
* We also use Purity to adjust coverage reporting thresholds.
* Genome-wide CNV segments with breakpoint information. Includes segment CN, minor/major allele ploidy, type of SV support at start/end of segment, CN determination method, BAF/BAF count, GC%, Cobalt window coverage


## MultiQC

MultiQC aggregates QC from different tools. We report the following:
	
* Sample contamination level (for both tumor and normal) and tumor/normal concordance (by [Conpair](https://github.com/nygenome/Conpair)),
* Ancestry and sex (by [Peddy](https://github.com/brentp/peddy)),
* Mapping QC: the number of mapped reads, paired reads, secondary or duplicated alignments, average coverage (using samtools stats and mosdepth in bcbio),
* Viral content and integration sites ([oncoviruses](https://github.com/umccr/oncoviruses)),
* PURPLE stats: QC, sex, purity/ploidy, TMB and MSI statuses
* Number of pre- and post-filtered SNPs and indels (by Umccrise) which indicates germline leakage,
* Coverage profile by goleft,
* Variants QC for filtered germline and somatic variants (by bcftools),
* Reads QC (by FastQC).

We also include reference "good" samples in the background for comparison.


## Coverage

The idea is to see if we can miss variants due to abnormal coverage (e.g. because of copy numbers or abnormal GC).

* Run [`goleft indexcov`](https://github.com/brentp/goleft/tree/master/indexcov) to plot fast global coverage overview from a BAM or CRAM index.
* Run [`mosdepth`](https://github.com/brentp/mosdepth) to calculate quantized coverage in exons of cancer genes if interest, using 4 groups for quantization: NO_COVERAGE, LOW_COVERAGE, CALLABLE, HIGH_COVERAGE. For tumor, the thresholds are adjusted by average purity (as reported by PURPLE). The low coverage threshold is 12x divided by purity (the minimal coverage to call a pure heterozugous variant), the high coverage threshold is 100 divided by purity (suspiciously high coverage, might indicate an LCR, a repeat, or a CN).
* Run [CACAO](https://github.com/sigven/cacao) using the same thresholds to calculate coverage in loci of interest. For germline variants, use [ClinVar](https://www.ncbi.nlm.nih.gov/clinvar) predisposition variants. For somatic variants, use [CiViC](https://civicdb.org/) actionable variants and [cancerhotspots.org](https://www.cancerhotspots.org/) somatic hotspots. This step generates two HTML reports (one for somatic, one for germline variants).


## Reports

Umccrise produces 6 reports:

* [PCGR](https://github.com/sigven/pcgr) containing small somatic variants (SNPs and indels) classified according to [ACMG](https://www.ncbi.nlm.nih.gov/pubmed/27993330) guidelines, and MSI status of the sample.
* [CPSR](https://github.com/sigven/cpsr) containing small germline variants (SNPs and indels) in cancer predisposition genes, ranked by ACMG guidelines and cancer-specific criteria.
* [CACAO](https://github.com/sigven/cacao) for tumor sample, reporting coverage for clinically actionable and pathogenic loci in cancer
* CACAO for normal sample, reporting coverage in likely pathogenic variants cancer predisposition protein-coding genes
* [MultiQC](https://multiqc.info) report with QC stats and plots
* UMCCR cancer report containing:
	* Somatic mutation profile (global and in cancer genes),
	* Mutational signatures (by the MutationalPatterns R package),
	* Structural variants,
	* Copy number variants,
	* PURPLE QC status,
	* Circos plot,
	* Oncoviral content and integration sites.


## Key cancer genes

For reporting and variant prioritization, we prepared a [UMCCR cancer key genes set](https://github.com/vladsaveliev/NGS_Utils/blob/master/ngs_utils/reference_data/key_genes/make_umccr_cancer_genes.Rmd). It's build of off several sources:

* Cancermine with at least 2 publication with at least 3 citations,
* NCG known cancer genes,
* Tier 1 COSMIC Cancer Gene Census (CGC),
* CACAO hotspot genes (curated from ClinVar, CiViC, cancerhotspots),
* At least 2 matches in the following 5 sources and 8 clinical panels:
   * Cancer predisposition genes (CPSR list),
   * COSMIC Cancer Gene Census (tier 2),
   * AZ300, 
   * Familial Cancer, 
   * OncoKB annotated,
   * MSKC-IMPACT, 
   * MSKC-Heme, 
   * PMCC-CCP, 
   * Illumina-TS500, 
   * TEMPUS, 
   * Foundation One, 
   * Foundation Heme, 
   * Vogelstein.

The result is a list of 1248 genes.

