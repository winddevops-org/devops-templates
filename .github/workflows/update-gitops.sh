#!/bin/bash
set -e

# Vérification du token
if [ -z "${GITOPS_PAT}" ]; then
  echo "❌ ERREUR CRITIQUE: Le secret GITOPS_TOKEN est vide ou non transmis !"
  exit 1
fi

APP_NAME="${APP_NAME}"
SHA="${SHA}"
DB_TYPE="${DB_TYPE}"
DEPLOY_MODE="${DEPLOY_MODE}"
REGISTRY="192.168.1.239:8085/selfkhaoula"
GITOPS_REPO="https://x-access-token:${GITOPS_PAT}@github.com/winddevops-org/gitops-environments.git"

git clone "${GITOPS_REPO}" gitops-environments
cd gitops-environments
git config user.email "ci@github.com"
git config user.name "GitHub Actions"
git remote set-url origin "${GITOPS_REPO}"

write_values() {
  local COMP="$1" REPO="$2" TAG="$3"
  local VPATH="environments/staging/${COMP}/values.yaml"
  mkdir -p "$(dirname "${VPATH}")"
  if [ ! -f "${VPATH}" ]; then
    printf 'name: %s\nreplicaCount: 1\nimage:\n  repository: "%s"\n  tag: "%s"\n  pullPolicy: IfNotPresent\nimagePullSecrets:\n  - name: nexus-registry-secret\nservice:\n  type: ClusterIP\n  port: 80\n  targetPort: 80\ningress:\n  enabled: true\n  className: nginx\n  host: %s.staging.local\n  path: /\n  pathType: Prefix\nresources:\n  limits:\n    cpu: 500m\n    memory: 512Mi\n  requests:\n    cpu: 250m\n    memory: 256Mi\n' \
      "${COMP}" "${REPO}" "${TAG}" "${COMP}" > "${VPATH}"
  else
    sed -i "s|repository:.*|repository: \"${REPO}\"|" "${VPATH}"
    sed -i "s|tag:.*|tag: \"${TAG}\"|"                "${VPATH}"
  fi
}

write_argocd() {
  local COMP="$1"
  local APATH="argocd-applications/${COMP}.yaml"
  mkdir -p argocd-applications
  [ -f "${APATH}" ] && return 0
  printf 'apiVersion: argoproj.io/v1alpha1\nkind: Application\nmetadata:\n  name: %s\n  namespace: argocd\nspec:\n  project: stagiaires\n  sources:\n    - repoURL: https://github.com/winddevops-org/devops-templates\n      targetRevision: main\n      path: helm-charts/app-generic\n      helm:\n        valueFiles:\n          - $values/environments/staging/%s/values.yaml\n    - repoURL: https://github.com/winddevops-org/gitops-environments\n      targetRevision: main\n      ref: values\n  destination:\n    server: https://kubernetes.default.svc\n    namespace: staging-%s\n  syncPolicy:\n    automated:\n      prune: true\n      selfHeal: true\n    syncOptions:\n      - CreateNamespace=true\n' \
      "${COMP}" "${COMP}" "${COMP}" > "${APATH}"
}

write_database() {
  local COMP="$1"
  local DBPATH="environments/staging/${COMP}/database.yaml"

  if [ "${DB_TYPE}" = "none" ] || [ "${DB_TYPE}" = "h2" ]; then
    echo "ℹ️ Pas de base de données externe nécessaire pour ${COMP}"
    return 0
  fi

  if [ -f "${DBPATH}" ]; then
    echo "⚠️ Base de données déjà existante, ignorée."
    return 0
  fi

  mkdir -p "$(dirname "${DBPATH}")"

  if [ "${DB_TYPE}" = "postgresql" ]; then
    cat > "${DBPATH}" <<'DBEOF'
---
apiVersion: v1
kind: Service
metadata:
  name: postgres-service-COMP_PLACEHOLDER
  namespace: staging-COMP_PLACEHOLDER
spec:
  selector:
    app: postgres-db-COMP_PLACEHOLDER
  ports:
    - port: 5432
      targetPort: 5432
  clusterIP: None
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres-db-COMP_PLACEHOLDER
  namespace: staging-COMP_PLACEHOLDER
spec:
  serviceName: "postgres-service-COMP_PLACEHOLDER"
  replicas: 1
  selector:
    matchLabels:
      app: postgres-db-COMP_PLACEHOLDER
  template:
    metadata:
      labels:
        app: postgres-db-COMP_PLACEHOLDER
    spec:
      containers:
        - name: postgres
          image: postgres:15-alpine
          ports:
            - containerPort: 5432
          env:
            - name: POSTGRES_DB
              value: "DBNAME_PLACEHOLDER"
            - name: POSTGRES_USER
              value: "admin"
            - name: POSTGRES_PASSWORD
              value: "changeme123"
            - name: PGDATA
              value: "/var/lib/postgresql/data/pgdata"
          volumeMounts:
            - name: postgres-storage
              mountPath: /var/lib/postgresql/data
          resources:
            requests:
              memory: "256Mi"
              cpu: "250m"
            limits:
              memory: "512Mi"
              cpu: "500m"
          readinessProbe:
            exec:
              command: ["pg_isready", "-U", "admin"]
            initialDelaySeconds: 10
            periodSeconds: 5
  volumeClaimTemplates:
    - metadata:
        name: postgres-storage
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 1Gi
DBEOF
    sed -i "s/COMP_PLACEHOLDER/${COMP}/g" "${DBPATH}"
    sed -i "s/DBNAME_PLACEHOLDER/${COMP//-/_}_db/g" "${DBPATH}"
    echo "✅ PostgreSQL généré pour ${COMP}"

  elif [ "${DB_TYPE}" = "mysql" ]; then
    cat > "${DBPATH}" <<'DBEOF'
---
apiVersion: v1
kind: Service
metadata:
  name: mysql-service-COMP_PLACEHOLDER
  namespace: staging-COMP_PLACEHOLDER
spec:
  selector:
    app: mysql-db-COMP_PLACEHOLDER
  ports:
    - port: 3306
      targetPort: 3306
  clusterIP: None
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mysql-db-COMP_PLACEHOLDER
  namespace: staging-COMP_PLACEHOLDER
spec:
  serviceName: "mysql-service-COMP_PLACEHOLDER"
  replicas: 1
  selector:
    matchLabels:
      app: mysql-db-COMP_PLACEHOLDER
  template:
    metadata:
      labels:
        app: mysql-db-COMP_PLACEHOLDER
    spec:
      containers:
        - name: mysql
          image: mysql:8.0
          ports:
            - containerPort: 3306
          env:
            - name: MYSQL_DATABASE
              value: "DBNAME_PLACEHOLDER"
            - name: MYSQL_USER
              value: "admin"
            - name: MYSQL_PASSWORD
              value: "changeme123"
            - name: MYSQL_ROOT_PASSWORD
              value: "rootpassword123"
          volumeMounts:
            - name: mysql-storage
              mountPath: /var/lib/mysql
          resources:
            requests:
              memory: "256Mi"
              cpu: "250m"
            limits:
              memory: "512Mi"
              cpu: "500m"
          readinessProbe:
            exec:
              command: ["mysqladmin", "ping", "-h", "localhost"]
            initialDelaySeconds: 15
            periodSeconds: 5
  volumeClaimTemplates:
    - metadata:
        name: mysql-storage
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 1Gi
DBEOF
    sed -i "s/COMP_PLACEHOLDER/${COMP}/g" "${DBPATH}"
    sed -i "s/DBNAME_PLACEHOLDER/${COMP//-/_}_db/g" "${DBPATH}"
    echo "✅ MySQL généré pour ${COMP}"

  elif [ "${DB_TYPE}" = "mongodb" ]; then
    cat > "${DBPATH}" <<'DBEOF'
---
apiVersion: v1
kind: Service
metadata:
  name: mongodb-service-COMP_PLACEHOLDER
  namespace: staging-COMP_PLACEHOLDER
spec:
  selector:
    app: mongodb-COMP_PLACEHOLDER
  ports:
    - port: 27017
      targetPort: 27017
  clusterIP: None
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mongodb-COMP_PLACEHOLDER
  namespace: staging-COMP_PLACEHOLDER
spec:
  serviceName: "mongodb-service-COMP_PLACEHOLDER"
  replicas: 1
  selector:
    matchLabels:
      app: mongodb-COMP_PLACEHOLDER
  template:
    metadata:
      labels:
        app: mongodb-COMP_PLACEHOLDER
    spec:
      containers:
        - name: mongodb
          image: mongo:6.0
          ports:
            - containerPort: 27017
          env:
            - name: MONGO_INITDB_DATABASE
              value: "DBNAME_PLACEHOLDER"
            - name: MONGO_INITDB_ROOT_USERNAME
              value: "admin"
            - name: MONGO_INITDB_ROOT_PASSWORD
              value: "changeme123"
          volumeMounts:
            - name: mongodb-storage
              mountPath: /data/db
          resources:
            requests:
              memory: "256Mi"
              cpu: "250m"
            limits:
              memory: "512Mi"
              cpu: "500m"
          readinessProbe:
            exec:
              command: ["mongosh", "--eval", "db.adminCommand('ping')"]
            initialDelaySeconds: 10
            periodSeconds: 5
  volumeClaimTemplates:
    - metadata:
        name: mongodb-storage
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 1Gi
DBEOF
    sed -i "s/COMP_PLACEHOLDER/${COMP}/g" "${DBPATH}"
    sed -i "s/DBNAME_PLACEHOLDER/${COMP//-/_}_db/g" "${DBPATH}"
    echo "✅ MongoDB généré pour ${COMP}"
  fi
}

inject_db_env() {
  local COMP="$1"
  local VPATH="environments/staging/${COMP}/values.yaml"
  local DB_NAME="${COMP//-/_}_db"

  if [ "${DB_TYPE}" = "none" ] || [ "${DB_TYPE}" = "h2" ]; then
    return 0
  fi

  if grep -q "DATASOURCE_URL\|DATABASE_URL\|MONGO_URI" "${VPATH}" 2>/dev/null; then
    echo "⚠️ Variables DB déjà présentes, ignorées."
    return 0
  fi

  if [ "${DB_TYPE}" = "postgresql" ]; then
    cat >> "${VPATH}" <<'ENVEOF'

env:
  - name: SPRING_DATASOURCE_URL
    value: "jdbc:postgresql://postgres-service-COMP_PLACEHOLDER:5432/DBNAME_PLACEHOLDER"
  - name: SPRING_DATASOURCE_USERNAME
    value: "admin"
  - name: SPRING_DATASOURCE_PASSWORD
    value: "changeme123"
  - name: SPRING_JPA_HIBERNATE_DDL_AUTO
    value: "update"
ENVEOF
    sed -i "s/COMP_PLACEHOLDER/${COMP}/g" "${VPATH}"
    sed -i "s/DBNAME_PLACEHOLDER/${DB_NAME}/g" "${VPATH}"
    echo "✅ Variables PostgreSQL injectées pour ${COMP}"

  elif [ "${DB_TYPE}" = "mysql" ]; then
    cat >> "${VPATH}" <<'ENVEOF'

env:
  - name: SPRING_DATASOURCE_URL
    value: "jdbc:mysql://mysql-service-COMP_PLACEHOLDER:3306/DBNAME_PLACEHOLDER?useSSL=false&allowPublicKeyRetrieval=true"
  - name: SPRING_DATASOURCE_USERNAME
    value: "admin"
  - name: SPRING_DATASOURCE_PASSWORD
    value: "changeme123"
  - name: SPRING_JPA_HIBERNATE_DDL_AUTO
    value: "update"
ENVEOF
    sed -i "s/COMP_PLACEHOLDER/${COMP}/g" "${VPATH}"
    sed -i "s/DBNAME_PLACEHOLDER/${DB_NAME}/g" "${VPATH}"
    echo "✅ Variables MySQL injectées pour ${COMP}"

  elif [ "${DB_TYPE}" = "mongodb" ]; then
    cat >> "${VPATH}" <<'ENVEOF'

env:
  - name: SPRING_DATA_MONGODB_URI
    value: "mongodb://admin:changeme123@mongodb-service-COMP_PLACEHOLDER:27017/DBNAME_PLACEHOLDER?authSource=admin"
ENVEOF
    sed -i "s/COMP_PLACEHOLDER/${COMP}/g" "${VPATH}"
    sed -i "s/DBNAME_PLACEHOLDER/${DB_NAME}/g" "${VPATH}"
    echo "✅ Variables MongoDB injectées pour ${COMP}"
  fi
}

case "${DEPLOY_MODE}" in
  mono)
    write_values "${APP_NAME}"       "${REGISTRY}/${APP_NAME}"       "${SHA}"
    write_argocd "${APP_NAME}"
    write_database "${APP_NAME}"
    inject_db_env "${APP_NAME}"
    COMMIT_MSG="[${APP_NAME}] deploy -> ${SHA}"
    ;;
  front-only)
    write_values "${APP_NAME}-front" "${REGISTRY}/${APP_NAME}-front" "${SHA}"
    write_argocd "${APP_NAME}-front"
    COMMIT_MSG="[${APP_NAME}] deploy front -> ${SHA}"
    ;;
  back-only)
    write_values "${APP_NAME}-back"  "${REGISTRY}/${APP_NAME}-back"  "${SHA}"
    write_argocd "${APP_NAME}-back"
    write_database "${APP_NAME}-back"
    inject_db_env "${APP_NAME}-back"
    COMMIT_MSG="[${APP_NAME}] deploy back -> ${SHA}"
    ;;
  dual)
    write_values "${APP_NAME}-front" "${REGISTRY}/${APP_NAME}-front" "${SHA}"
    write_values "${APP_NAME}-back"  "${REGISTRY}/${APP_NAME}-back"  "${SHA}"
    write_argocd "${APP_NAME}-front"
    write_argocd "${APP_NAME}-back"
    write_database "${APP_NAME}-back"
    inject_db_env "${APP_NAME}-back"
    COMMIT_MSG="[${APP_NAME}] deploy front+back -> ${SHA}"
    ;;
esac

git add .
if git diff --cached --quiet; then
  echo "Rien à commiter."
  exit 0
fi
git commit -m "${COMMIT_MSG}"
git pull --rebase origin main
git push origin main
