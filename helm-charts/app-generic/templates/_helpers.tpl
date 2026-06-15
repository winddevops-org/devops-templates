{{- define "app-generic.dbPort" -}}
{{- if eq .Values.database.type "postgresql" }}5432
{{- else if eq .Values.database.type "mysql" }}3306
{{- else if eq .Values.database.type "mongodb" }}27017
{{- else }}5432
{{- end }}
{{- end }}

{{- define "app-generic.dbServiceName" -}}
{{- printf "%s-%s-svc" (.Values.name | default .Release.Name) .Values.database.type }}
{{- end }}

{{- define "app-generic.dbStatefulSetName" -}}
{{- printf "%s-%s" (.Values.name | default .Release.Name) .Values.database.type }}
{{- end }}

{{- define "app-generic.dbSecretName" -}}
{{- if .Values.database.secretName }}
{{- .Values.database.secretName }}
{{- else }}
{{- printf "%s-db-secret" (.Values.name | default .Release.Name) }}
{{- end }}
{{- end }}

{{- define "app-generic.dbImage" -}}
{{- if eq .Values.database.type "postgresql" }}postgres:15-alpine
{{- else if eq .Values.database.type "mysql" }}mysql:8.0
{{- else if eq .Values.database.type "mongodb" }}mongo:6.0
{{- end }}
{{- end }}

{{- define "app-generic.dbEnvVars" -}}
{{- if and .Values.database.enabled .Values.database.type }}
{{- $svcName    := include "app-generic.dbServiceName" . }}
{{- $secretName := include "app-generic.dbSecretName" . }}
{{- $dbName     := .Values.database.name }}
{{- if eq .Values.database.type "postgresql" }}
- name: SPRING_DATASOURCE_URL
  value: "jdbc:postgresql://{{ $svcName }}:5432/{{ $dbName }}"
- name: SPRING_DATASOURCE_USERNAME
  valueFrom:
    secretKeyRef:
      name: {{ $secretName }}
      key: username
- name: SPRING_DATASOURCE_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ $secretName }}
      key: password
- name: SPRING_JPA_HIBERNATE_DDL_AUTO
  value: "update"
{{- else if eq .Values.database.type "mysql" }}
- name: SPRING_DATASOURCE_URL
  value: "jdbc:mysql://{{ $svcName }}:3306/{{ $dbName }}?useSSL=false&allowPublicKeyRetrieval=true"
- name: SPRING_DATASOURCE_USERNAME
  valueFrom:
    secretKeyRef:
      name: {{ $secretName }}
      key: username
- name: SPRING_DATASOURCE_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ $secretName }}
      key: password
- name: SPRING_JPA_HIBERNATE_DDL_AUTO
  value: "update"
{{- else if eq .Values.database.type "mongodb" }}
- name: SPRING_DATA_MONGODB_URI
  value: "mongodb://$(MONGO_USER):$(MONGO_PASSWORD)@{{ $svcName }}:27017/{{ $dbName }}?authSource=admin"
- name: MONGO_USER
  valueFrom:
    secretKeyRef:
      name: {{ $secretName }}
      key: username
- name: MONGO_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ $secretName }}
      key: password
{{- end }}
{{- end }}
{{- end }}
