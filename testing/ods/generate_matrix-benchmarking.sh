#! /bin/bash

THIS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

MATBENCH_WORKLOAD_NAME=rhods-ci
MATBENCH_EXPE_NAME=rhods-ci
ARTIFACT_DIR=${ARTIFACT_DIR:-/tmp/ci-artifacts_$(date +%Y%m%d)}
MATBENCH_RESULTS_DIR="/tmp/matrix_benchmarking_results"

WORKLOAD_STORAGE_DIR="$THIS_DIR/../../subprojects/matrix-benchmarking-workloads/$MATBENCH_WORKLOAD_NAME"
WORKLOAD_RUN_DIR="$THIS_DIR/../../subprojects/matrix-benchmarking/workloads/$MATBENCH_WORKLOAD_NAME"

MATBENCH_DATA_URL=""

if [[ "${ARTIFACT_DIR:-}" ]] && [[ -f "${ARTIFACT_DIR}/variable_overrides" ]]; then
    source "${ARTIFACT_DIR}/variable_overrides"
fi

generate_matbench::prepare_matrix_benchmarking() {
    rm -f "$WORKLOAD_RUN_DIR"
    ln -s "$WORKLOAD_STORAGE_DIR" "$WORKLOAD_RUN_DIR"

    pip install --quiet --requirement "$THIS_DIR/../../subprojects/matrix-benchmarking/requirements.txt"
    pip install --quiet --requirement "$WORKLOAD_STORAGE_DIR/requirements.txt"
}

_get_data_from_pr() {
    results_dir=$1
    shift

    VARIABLE_OVERRIDES_FILE="${ARTIFACT_DIR}/variable_overrides"

    if [[ ! -f "$VARIABLE_OVERRIDES_FILE" ]]; then
        echo "ERROR: _get_data_from_pr expects $VARIABLE_OVERRIDES_FILE to exit ..."
        exit 1
    fi

    source "$VARIABLE_OVERRIDES_FILE"

    if [[ -z "$PR_POSITIONAL_ARGS" ]]; then
        echo "ERROR: _get_data_from_pr expects $VARIABLE_OVERRIDES_FILE to contain PR_POSITIONAL_ARGS ..."
        exit 1
    fi

    matbench_url="$PR_POSITIONAL_ARGS"

    echo "$matbench_url" > "${ARTIFACT_DIR}/source_url"

    _download_data_from_url "$results_dir" "$matbench_url"
}

_download_data_from_url() {
    results_dir=$1
    shift
    url=$1
    shift

    if [[ "${url: -1}" != "/" ]]; then
        url="${url}/"
    fi

    mkdir -p "$results_dir"

    dl_dir=$(echo "$url" | cut -d/ -f4-)
    (cd "$results_dir"; wget --recursive --no-host-directories --no-parent --execute robots=off --quiet \
                             --cut-dirs=$(echo "${dl_dir}" | tr -cd / | wc -c) \
                             "$url")
}

_prepare_data_from_artifacts_dir() {
    artifact_dir=$1

    rm -f "$MATBENCH_RESULTS_DIR/$MATBENCH_EXPE_NAME"
    mkdir -p "$MATBENCH_RESULTS_DIR"
    ln -s "$artifact_dir" "$MATBENCH_RESULTS_DIR/$MATBENCH_EXPE_NAME"
}

generate_matbench::get_prometheus() {
    PROMETHEUS_VERSION=2.36.0
    cd /tmp
    wget --quiet "https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz" -O/tmp/prometheus.tar.gz
    tar xf "/tmp/prometheus.tar.gz" -C /tmp
    mkdir -p /tmp/bin
    ln -sf "/tmp/prometheus-${PROMETHEUS_VERSION}.linux-amd64/prometheus" /tmp/bin
    ln -sf "/tmp/prometheus-${PROMETHEUS_VERSION}.linux-amd64/prometheus.yml" /tmp/
    export PATH=$PATH:/tmp/bin
}

generate_matbench::generate_plots() {
    ln -sf /tmp/prometheus.yml "$WORKLOAD_STORAGE_DIR"

    cat > "$WORKLOAD_STORAGE_DIR/.env" <<EOF
MATBENCH_RESULTS_DIRNAME=$MATBENCH_RESULTS_DIR
MATBENCH_FILTERS=expe=$MATBENCH_EXPE_NAME
EOF

    cat "$WORKLOAD_STORAGE_DIR/.env"

    _matbench() {
        (cd "$WORKLOAD_RUN_DIR"; matbench "$@")
    }

    stats_content="$(cat "$WORKLOAD_STORAGE_DIR/data/ci-artifacts.plots")"

    echo "$stats_content"

    generate_url="stats=$(echo -n "$stats_content" | tr '\n' '&' | sed 's/&/&stats=/g')"

    _matbench parse

    retcode=0
    VISU_LOG_FILE="$ARTIFACT_DIR/_matbench_visualize.log"
    if ! _matbench visualize --generate="$generate_url" |& tee > "$VISU_LOG_FILE"; then
        echo "Visualization generation failed :("
        retcode=1
    fi

    mkdir -p "$ARTIFACT_DIR"/figures_{png,html}

    mv "$WORKLOAD_STORAGE_DIR"/fig_*.png "$ARTIFACT_DIR/figures_png" || true
    mv "$WORKLOAD_STORAGE_DIR"/fig_*.html "$ARTIFACT_DIR/figures_html" || true
    mv "$WORKLOAD_STORAGE_DIR"/report_* "$ARTIFACT_DIR" || true
    mv "$WORKLOAD_STORAGE_DIR"/reports_* "$ARTIFACT_DIR" || true

    if grep "^ERROR" "$VISU_LOG_FILE"; then
        echo "An error happened during the report generation, aborting."
        grep "^ERROR" "$VISU_LOG_FILE" > "$ARTIFACT_DIR"/FAILURE
        exit 1
    fi

    return $retcode
}

action=${1:-}

if [[ "$action" == "prepare_matbench" ]]; then
    set -o errexit
    set -o pipefail
    set -o nounset
    set -x

    generate_matbench::get_prometheus
    generate_matbench::prepare_matrix_benchmarking

elif [[ "$action" == "generate_plots" ]]; then
    set -o errexit
    set -o pipefail
    set -o nounset
    set -x

    _prepare_data_from_artifacts_dir "$ARTIFACT_DIR/.."

    generate_matbench::generate_plots

elif [[ "$JOB_NAME_SAFE" == "nb-on-"* || "$JOB_NAME_SAFE" == get-cluster ]]; then
    set -o errexit
    set -o pipefail
    set -o nounset
    set -x

    _prepare_data_from_artifacts_dir "$ARTIFACT_DIR/.."

    generate_matbench::get_prometheus
    generate_matbench::prepare_matrix_benchmarking

    generate_matbench::generate_plots

elif [[ "$JOB_NAME_SAFE" == "plot-nb-on-"* ]]; then
    set -o errexit
    set -o pipefail
    set -o nounset
    set -x

    results_dir="$MATBENCH_RESULTS_DIR/$MATBENCH_EXPE_NAME"
    mkdir -p "$results_dir"

    _get_data_from_pr "$results_dir"

    generate_matbench::get_prometheus
    generate_matbench::prepare_matrix_benchmarking

    generate_matbench::generate_plots
fi
