include { BAM_MERGE_INDEX_SAMTOOLS                 } from '../bam_merge_index_samtools/main'
include { VCF_VARIANT_FILTERING_GATK               } from '../vcf_variant_filtering_gatk/main'
include { SENTIEON_HAPLOTYPER                      } from '../../../modules/nf-core/sentieon/haplotyper/main'

include { GATK4_MERGEVCFS as MERGE_SENTIEON_HAPLOTYPER_VCFS  } from '../../../modules/nf-core/gatk4/mergevcfs/main'
include { GATK4_MERGEVCFS as MERGE_SENTIEON_HAPLOTYPER_GVCFS } from '../../../modules/nf-core/gatk4/mergevcfs/main'

workflow BAM_VARIANT_CALLING_SENTIEON_HAPLOTYPER {
    take:
    cram                         // channel: [mandatory] [ meta, cram, crai, interval.bed ]
    fasta                        // channel: [mandatory]
    fasta_fai                    // channel: [mandatory]
    dict                         // channel: [mandatory]
    dbsnp                        // channel: [optional]
    dbsnp_tbi                    // channel: [optional]
    dbsnp_vqsr                   // channel: [optional]
    known_sites_indels           // channel: [optional]
    known_sites_indels_tbi       // channel: [optional]
    known_indels_vqsr            // channel: [optional]
    known_sites_snps             // channel: [optional]
    known_sites_snps_tbi         // channel: [optional]
    known_snps_vqsr              // channel: [optional]
    intervals                    // channel: [mandatory] [ intervals, num_intervals ] or [ [], 0 ] if no intervals
    intervals_bed_combined       // channel: [mandatory] intervals/target regions in one file unzipped, no_intervals.bed if no_intervals
    skip_haplotyper_filter       // boolean: [mandatory] [default: false] skip haplotyper filter

    main:
    versions = Channel.empty()

    gvcf = Channel.empty()
    vcf = Channel.empty()
    genotype_intervals = Channel.empty()

    // Combine cram and intervals for spread and gather strategy
    cram_intervals_for_sentieon = cram.combine(intervals)
        // Move num_intervals to meta map
        .map{ meta, cram, crai, intervals, num_intervals -> [ meta + [ num_intervals:num_intervals ], cram, crai, intervals ] }

    if (params.joint_germline) {  // TO-DO:  Try to also to implementemit_mode "both"
        // TO-DO: emit_mode should also be set to `gvcf` when just requesting gvcf-files but not wanting joint-germline analysis.
        emit_mode = 'gvcf'
    } else {
        emit_mode = 'vcf'
    }

    println("emit_mode : " + emit_mode)

    SENTIEON_HAPLOTYPER(
        emit_mode,
        cram_intervals_for_sentieon,
        fasta,
        fasta_fai,
        dbsnp,
        dbsnp_tbi)

    versions = versions.mix(SENTIEON_HAPLOTYPER.out.versions)

    if (params.joint_germline) {
        genotype_intervals = SENTIEON_HAPLOTYPER.out.gvcf
            .join(SENTIEON_HAPLOTYPER.out.gvcf_tbi, failOnMismatch: true)
            .join(cram_intervals_for_sentieon, failOnMismatch: true)
            .map{ meta, gvcf, tbi, cram, crai, intervals -> [ meta, gvcf, tbi, intervals ] }
    }

    // Figure out if using intervals or no_intervals
    SENTIEON_HAPLOTYPER.out.vcf.branch{
            intervals:    it[0].num_intervals > 1
            no_intervals: it[0].num_intervals <= 1
        }.set{haplotyper_vcf_branch}


    SENTIEON_HAPLOTYPER.out.vcf_tbi.branch{
            intervals:    it[0].num_intervals > 1
            no_intervals: it[0].num_intervals <= 1
        }.set{haplotyper_vcf_tbi_branch}

    SENTIEON_HAPLOTYPER.out.gvcf.branch{
            intervals:    it[0].num_intervals > 1
            no_intervals: it[0].num_intervals <= 1
        }.set{haplotyper_gvcf_branch}

    SENTIEON_HAPLOTYPER.out.gvcf_tbi.branch{
            intervals:    it[0].num_intervals > 1
            no_intervals: it[0].num_intervals <= 1
        }.set{haplotyper_gvcf_tbi_branch}

    // VCFs
    // Only when using intervals
    MERGE_SENTIEON_HAPLOTYPER_VCFS(
        haplotyper_vcf_branch.intervals.map{ meta, vcf ->
            new_meta = [
                            id:             meta.sample,
                            num_intervals:  meta.num_intervals,
                            patient:        meta.patient,
                            sample:         meta.sample,
                            sex:            meta.sex,
                            status:         meta.status,
                            variantcaller:  "sentieon_haplotyper"
                        ]
            [groupKey(new_meta, new_meta.num_intervals), vcf] }
            .groupTuple(),
        dict.map{it -> [ [ id:'dict' ], it ]})

    versions = versions.mix(MERGE_SENTIEON_HAPLOTYPER_VCFS.out.versions)

    haplotyper_vcf = Channel.empty().mix(
        MERGE_SENTIEON_HAPLOTYPER_VCFS.out.vcf,
        haplotyper_vcf_branch.no_intervals)

    haplotyper_tbi = Channel.empty().mix(
        MERGE_SENTIEON_HAPLOTYPER_VCFS.out.tbi,
        haplotyper_vcf_tbi_branch.no_intervals)

    if (!skip_haplotyper_filter) {
        VCF_VARIANT_FILTERING_GATK(haplotyper_vcf.join(haplotyper_tbi),
                    fasta,
                    fasta_fai,
                    dict,
                    intervals_bed_combined,
                    known_sites_indels.concat(known_sites_snps).flatten().unique().collect(),
                    known_sites_indels_tbi.concat(known_sites_snps_tbi).flatten().unique().collect())

        vcf = VCF_VARIANT_FILTERING_GATK.out.filtered_vcf.map{ meta, vcf-> [[patient:meta.patient, sample:meta.sample, status:meta.status, sex:meta.sex, id:meta.sample, num_intervals:meta.num_intervals, variantcaller:"sentieon_haplotyper"], vcf]}
        versions = versions.mix(VCF_VARIANT_FILTERING_GATK.out.versions)

    } else vcf = haplotyper_vcf

    // add variantcaller to meta map and remove no longer necessary field: num_intervals
    vcf = vcf.map{ meta, vcf -> [ meta - meta.subMap('num_intervals') + [ variantcaller:'sentieon_haplotyper' ], vcf ] }

    // GVFs
    // Only when using intervals
    MERGE_SENTIEON_HAPLOTYPER_GVCFS(
        haplotyper_gvcf_branch.intervals
        .map{ meta, gvcf ->
            new_meta = [
                            id:             meta.sample,
                            num_intervals:  meta.num_intervals,
                            patient:        meta.patient,
                            sample:         meta.sample,
                            sex:            meta.sex,
                            status:         meta.status,
                            variantcaller:  "sentieon_haplotyper"
                        ]

                [groupKey(new_meta, new_meta.num_intervals), gvcf]
            }.groupTuple(),
        dict.map{it -> [ [ id:'dict' ], it ]})

    versions = versions.mix(MERGE_SENTIEON_HAPLOTYPER_GVCFS.out.versions)

    gvcf = Channel.empty().mix(
        MERGE_SENTIEON_HAPLOTYPER_GVCFS.out.vcf,
        haplotyper_gvcf_branch.no_intervals)

    emit:
    versions
    vcf
    gvcf
    genotype_intervals // For joint genotyping

}
