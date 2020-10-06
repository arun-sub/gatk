version 1.0

import "CreateArrayImportTsvs.wdl" as CreateArrayImportTsvs

workflow ImportArrays {
  input {
    Array[File] input_vcfs
    Array[File]? input_metrics
    String? probe_info_table
    File? probe_info_file
    String output_directory
    File sampleMap
    String project_id
    String dataset_name

    Int? preemptible_tries
    File? gatk_override
    String? docker
  }

  String docker_final = select_first([docker, "us.gcr.io/broad-gatk/gatk:4.1.7.0"])

  scatter (i in range(length(input_vcfs))) {
    if (defined(input_metrics)) {
      File input_metric = select_first([input_metrics])[i]
    }

    call CreateArrayImportTsvs.CreateArrayImportTsvs as CreateArrayImportTsvs {
      input:
        input_vcf = input_vcfs[i],
        input_metrics = input_metric,
        probe_info_table = probe_info_table,
        probe_info_file = probe_info_file,
        output_directory = output_directory,
        sampleMap = sampleMap,
        preemptible_tries = preemptible_tries,
        gatk_override = gatk_override,
        docker = docker
    }
  }

  call LoadArrayTsvsToBQ {
    input:
      project_id = project_id,
      dataset_name = dataset_name,
      storage_location = output_directory,
      #TODO: figure out how to determine table_id
      table_id = 1,
      docker = docker_final
  }
}

task LoadArrayTsvsToBQ {
  input {
    String project_id
    String dataset_name
    String storage_location
    String table_id

    #runtime
    String docker
    Int? preemptible_tries

    String? for_testing_only
    String? uuid_table_name_for_testing
  }
  command<<<
    set -e
    ~{for_testing_only}

    PROJECT_ID=~{project_id}
    DATASET_NAME=~{dataset_name}
    STORAGE_LOCATION=~{storage_location}
    TABLE_ID=~{table_id}
    PROCESSING_DIR=$STORAGE_LOCATION/
    DONE_DIR=$STORAGE_LOCATION/done/

    let PARTITION_START=($TABLE_ID-1)*4000+1
    let PARTITION_END=$PARTITION_START+3999
    printf -v PADDED_TABLE_ID "%03d" $TABLE_ID

    RAW_FILES="raw_${PADDED_TABLE_ID}_*"
    METADATA_FILES="sample_${PADDED_TABLE_ID}_*"

    NUM_RAW_FILES=$(gsutil ls ${PROCESSING_DIR}${RAW_FILES} | wc -l)
    NUM_METADATA_FILES=$(gsutil ls $PROCESSING_DIR${METADATA_FILES} | wc -l)

    if [ $NUM_RAW_FILES -eq 0 -a $NUM_METADATA_FILES -eq 0 ]; then
      "no files for table ${PADDED_TABLE_ID} to process in $PROCESSING_DIR; exiting"
      exit
    fi

    # schema and TSV header need to be the same order
    RAW_SCHEMA="raw_array_schema.json"
    SAMPLE_LIST_SCHEMA="arrays_sample_list_schema.json"

    # create a metadata table and load
    SAMPLE_LIST_TABLE=$DATASET_NAME.sample_list
    if [ $NUM_METADATA_FILES -gt 0 ]; then
      set +e
      bq ls --project_id $PROJECT_ID $DATASET_NAME > /dev/null
      set -e
      if [ $? -ne 0 ]; then
        echo "making dataset $DATASET_NAME"
        bq mk --project_id=$PROJECT_ID $DATASET_NAME
      fi
      set +e
      bq show --project_id $PROJECT_ID $SAMPLE_LIST_TABLE > /dev/null
      set -e
      if [ $? -ne 0 ]; then
        echo "making table $SAMPLE_LIST_TABLE"
        bq --location=US mk --project_id=$PROJECT_ID $SAMPLE_LIST_TABLE $SAMPLE_LIST_SCHEMA
      fi
      bq load --location=US --project_id=$PROJECT_ID --skip_leading_rows=1 --null_marker="null" --source_format=CSV -F "\t" $SAMPLE_LIST_TABLE $PROCESSING_DIR$METADATA_FILES $SAMPLE_LIST_SCHEMA
      echo "ingested ${METADATA_FILES} file from $PROCESSING_DIR into table $SAMPLE_LIST_TABLE"
    else
      echo "no metadata files to process"
    fi

    # create array table
    TABLE=$DATASET_NAME.~{uuid_table_name_for_testing}arrays_$PADDED_TABLE_ID
    if [ $NUM_RAW_FILES -gt 0 ]; then
      set +e
      bq show --project_id $PROJECT_ID $TABLE > /dev/null
      set -e
      if [ $? -ne 0 ]; then
        echo "making table $TABLE"
        bq --location=US mk --range_partitioning=$PARTITION_FIELD,$PARTITION_START,$PARTITION_END,$PARTITION_STEP \
          --project_id=$PROJECT_ID $TABLE $RAW_SCHEMA
      fi
      bq load --location=US --project_id=$PROJECT_ID --skip_leading_rows=1 --null_marker="null" --source_format=CSV -F "\t" $TABLE $PROCESSING_DIR$RAW_FILES $RAW_SCHEMA
      echo "ingested ${RAW_FILES} files from $PROCESSING_DIR into table $TABLE"
    else
      echo "no raw data files to process"
    fi
    echo "moving files from processing to done"
    gsutil -q -m mv $PROCESSING_DIR$METADATA_FILES $DONE_DIR
    gsutil -q -m mv $PROCESSING_DIR$RAW_FILES $DONE_DIR
  >>>
  runtime {
    docker: docker
    memory: "4 GB"
    disks: "local-disk 10 HDD"
    preemptible: select_first([preemptible_tries, 5])
    cpu: 2
  }
}
