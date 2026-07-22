#!/bin/bash
set -e

if [ -z "${GITOPS_PAT}" ]; then
  echo "ERREUR CRITIQUE: Le secret GITOPS_TOKEN est vide ou non transmis"
  exit 1
fi

APP_NAME="${APP_NAME}"
SHA="${SHA}"
DB_TYPE="${DB_TYPE}"
DEPLOY_MODE="${DEPLOY_MODE}"
ENV="${ENV:-staging}"

# Sélection dynamique du registre
if [ "${ENV}" = "production" ]; then
  REGISTRY="windazureacr.azurecr.io"
  REPLICA_COUNT=2
else
  REGISTRY="192.168.1.239:8085/selfkhaoula"
  REPLICA_COUNT=1
fi

GITOPS_REPO="https://x-access-token:${GITOPS_PAT}@github.com/winddevops-org/gitops-environments.git"

git clone "${GITOPS_REPO}" gitops-environments
cd gitops-environments
git config user.email "ci@github.com"
git config user.name "GitHub Actions"
git remote set-url origin "${GITOPS_REPO}"

get_base_name() {
  local COMP="$1"
  echo "${COMP}" | sed -E 's/-(front|back)$//'
}

write_values() {
  local COMP="$1" REPO="$2" TAG="$3"
  local BASE_NAME=$(get_base_name "${COMP}")
  local COMPONENT="${COMP##*-}"
  local VPATH="environments/${ENV}/${BASE_NAME}/values-${COMPONENT}.yaml"
  
  mkdir -p "$(dirname "${VPATH}")"
  
  if [ ! -f "${VPATH}" ]; then
    cat > "${VPATH}" <<VALEOF
name: ${COMP}
namespace: ${ENV}-${BASE_NAME}
replicaCount: ${REPLICA_COUNT}
image:
  repository: "${REPO}"
  tag: "${TAG}"
  pullPolicy: IfNotPresent
imagePullSecrets:
  - name: nexus-registry-secret
service:
  type: ClusterIP
  port: 80
  targetPort: 80
ingress:
  enabled: true
  className: nginx
  host: ${COMP}.${ENV}.local
  path: /
  pathType: Prefix
resources:
  limits:
    cpu: 500m
    memory: 512Mi
  requests:
    cpu: 250m
    memory: 256Mi
env: []
database:
  enabled: false
  type: ""
  name: ""
  storage: 1Gi
  resources:
    limits:
      cpu: 500m
      memory: 512Mi
    requests:
      cpu: 250m
      memory: 256Mi
  ha:
    enabled: true
    replicas: 2
    proxy:
      enabled: true
      replicas: 2
VALEOF
    echo "values-${COMPONENT}.yaml cree pour ${COMP} dans namespace ${ENV}-${BASE_NAME}"
  else
    sed -i "s|repository:.*|repository: \"${REPO}\"|" "${VPATH}"
    sed -i "s|tag:.*|tag: \"${TAG}\"|" "${VPATH}"
    sed -i "s|replicaCount:.*|replicaCount: ${REPLICA_COUNT}|" "${VPATH}"
    echo "values-${COMPONENT}.yaml mis a jour pour ${COMP}"
  fi
}

write_db_values() {
  local COMP="$1"
  local BASE_NAME=$(get_base_name "${COMP}")
  local VPATH="environments/${ENV}/${BASE_NAME}/values-back.yaml"
  local DB_NAME="${BASE_NAME//-/_}_db"

  if [ "${DB_TYPE}" = "none" ] || [ "${DB_TYPE}" = "h2" ] || [ -z "${DB_TYPE}" ]; then
    echo "Pas de DB externe pour ${COMP}"
    return 0
  fi

  python3 - "${VPATH}" "${DB_TYPE}" "${DB_NAME}" "${ENV}" "${BASE_NAME}" <<'PYEOF'
import sys, re
path, db_type, db_name, env, base_name = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
with open(path) as f:
    content = f.read()

content = re.sub(r'\ndatabase:.*?(?=\n\S|\Z)', '', content, flags=re.DOTALL)

new_block = f"""
database:
  enabled: true
  type: "{db_type}"
  name: "{db_name}"
  namespace: "{env}-{base_name}"
  storage: 1Gi
  resources:
    limits:
      cpu: 500m
      memory: 512Mi
    requests:
      cpu: 250m
      memory: 256Mi
  ha:
    enabled: true
    replicas: 2
    proxy:
      enabled: true
      replicas: 2
"""

with open(path, 'w') as f:
    f.write(content.rstrip() + new_block)
print(f"database injecte : type={db_type}, name={db_name}, namespace={env}-{base_name}")
PYEOF
}

write_argocd() {
  local COMP="$1"
  local BASE_NAME=$(get_base_name "${COMP}")
  local COMPONENT="${COMP##*-}"
  local APATH="argocd-applications/${COMP}-${ENV}.yaml"
  
  mkdir -p argocd-applications
  [ -f "${APATH}" ] && return 0
  
  cat > "${APATH}" <<ARGOEOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${COMP}-${ENV}
  namespace: argocd
spec:
  project: stagiaires
  sources:
    - repoURL: https://github.com/winddevops-org/devops-templates
      targetRevision: main
      path: helm-charts/app-generic
      helm:
        valueFiles:
          - \$values/environments/${ENV}/${BASE_NAME}/values-${COMPONENT}.yaml
    - repoURL: https://github.com/winddevops-org/gitops-environments
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: ${ENV}-${BASE_NAME}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
ARGOEOF
  echo "ArgoCD Application creee pour ${COMP} dans namespace ${ENV}-${BASE_NAME}"
}

if [ -z "${DEPLOY_MODE}" ]; then
    HAS_FRONT=false
    HAS_BACK=false
    
    if [ -d "frontend" ] && [ -f "frontend/Dockerfile" ]; then
        HAS_FRONT=true
    fi
    if [ -d "backend" ] && [ -f "backend/Dockerfile" ]; then
        HAS_BACK=true
    fi
    
    if [ "${HAS_FRONT}" = "true" ] && [ "${HAS_BACK}" = "true" ]; then
        DEPLOY_MODE="dual"
    elif [ "${HAS_FRONT}" = "true" ]; then
        DEPLOY_MODE="front-only"
    elif [ "${HAS_BACK}" = "true" ]; then
        DEPLOY_MODE="back-only"
    else
        DEPLOY_MODE="mono"
    fi
    echo "Mode auto-detecte: ${DEPLOY_MODE}"
fi

case "${DEPLOY_MODE}" in
  mono)
    write_values "${APP_NAME}" "${REGISTRY}/${APP_NAME}" "${SHA}"
    write_argocd "${APP_NAME}"
    write_db_values "${APP_NAME}"
    COMMIT_MSG="[${APP_NAME}] deploy -> ${SHA} (env: ${ENV}, db: ${DB_TYPE})"
    ;;
  front-only)
    write_values "${APP_NAME}-front" "${REGISTRY}/${APP_NAME}-front" "${SHA}"
    write_argocd "${APP_NAME}-front"
    COMMIT_MSG="[${APP_NAME}] deploy front -> ${SHA} (env: ${ENV})"
    ;;
  back-only)
    write_values "${APP_NAME}-back" "${REGISTRY}/${APP_NAME}-back" "${SHA}"
    write_argocd "${APP_NAME}-back"
    write_db_values "${APP_NAME}-back"
    COMMIT_MSG="[${APP_NAME}] deploy back -> ${SHA} (env: ${ENV}, db: ${DB_TYPE})"
    ;;
  dual)
    write_values "${APP_NAME}-front" "${REGISTRY}/${APP_NAME}-front" "${SHA}"
    write_values "${APP_NAME}-back"  "${REGISTRY}/${APP_NAME}-back"  "${SHA}"
    write_argocd "${APP_NAME}-front"
    write_argocd "${APP_NAME}-back"
    write_db_values "${APP_NAME}-back"
    COMMIT_MSG="[${APP_NAME}] deploy front+back -> ${SHA} (env: ${ENV}, db: ${DB_TYPE})"
    ;;
  *)
    echo "DEPLOY_MODE inconnu : ${DEPLOY_MODE}"
    exit 1
    ;;
esac

git add .
if git diff --cached --quiet; then
  echo "Rien a commiter."
  exit 0
fi
git commit -m "${COMMIT_MSG}"
git pull --rebase origin main
git push origin main
