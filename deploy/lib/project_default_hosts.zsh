# Default deploy hosts (edit freely), shared by node_project.zsh and tail_node_project.zsh.
# Host used when no target host is given on the command line, keyed by the
# project name from config/node_projects.json. Projects not listed here fall
# back to DEFAULT_DEPLOY_HOST.
DEFAULT_DEPLOY_HOST="sky"
typeset -A PROJECT_DEFAULT_HOSTS=(
  healthcheck            sky
  bikespot-london        sky
  top-scores             sky
  top-scores-web         sky
  goal-guesser           sky
  sky-no-limit-web       sky
  train-track-api        sky
  train-track-planner    mini
  train-track-journey-planner mini
  tube-track-api         sky
  train-loading-service  sky
  bromley-bins           sky
  kidsplorers-api        sky
  kidsplorers-web        sky
  kidsplorers-events-worker mini
)

get_project_default_host() {
  echo "${PROJECT_DEFAULT_HOSTS[$1]:-$DEFAULT_DEPLOY_HOST}"
}
