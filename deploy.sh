chmod +rx /scripts/*


ENV=$1

./scripts/deploy_all.sh config/${ENV}-parameters.json 2>&1 | tee -a "deploy.log"
