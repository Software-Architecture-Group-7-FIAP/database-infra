#!/usr/bin/env bash

capture_ssm_get_parameters_batched() {
  local output_file="$1"
  local aws_bin="$2"
  local region="$3"
  local jq_bin="$4"
  local tmp_dir="$5"
  shift 5

  local -a names=("$@")
  local -a response_files=()
  local offset=0
  local batch_index=0
  local output_stem="${output_file##*/}"

  while (( offset < ${#names[@]} )); do
    local -a batch_names=("${names[@]:offset:10}")
    local response_file="$tmp_dir/$output_stem-batch-$batch_index.json"
    local error_file="$tmp_dir/$output_stem-batch-$batch_index.stderr"

    # SSM names begin with '/', which Git Bash/MSYS may rewrite as Windows paths.
    if ! MSYS_NO_PATHCONV=1 "$aws_bin" --region "$region" ssm get-parameters \
      --names "${batch_names[@]}" --output json > "$response_file" 2> "$error_file"; then
      return 1
    fi

    if ! "$jq_bin" -e \
      'type == "object" and (.Parameters | type == "array") and (.InvalidParameters | type == "array")' \
      "$response_file" >/dev/null 2>&1; then
      return 1
    fi

    response_files+=("$response_file")
    offset=$((offset + 10))
    batch_index=$((batch_index + 1))
  done

  "$jq_bin" -s '{
    Parameters: [ .[].Parameters[] ],
    InvalidParameters: [ .[].InvalidParameters[] ]
  }' "${response_files[@]}" > "$output_file"
}
