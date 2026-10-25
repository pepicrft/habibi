{{- define "habibi.image" -}}
{{- $tag := default .Chart.AppVersion .Values.image.tag -}}
{{- if .Values.image.digest -}}
{{ printf "%s:%s@%s" .Values.image.repository $tag .Values.image.digest }}
{{- else -}}
{{ printf "%s:%s" .Values.image.repository $tag }}
{{- end -}}
{{- end -}}

{{- define "habibi.labels" -}}
app.kubernetes.io/name: habibi
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "habibi.security" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
runAsNonRoot: true
runAsUser: 65534
runAsGroup: 65534
capabilities:
  drop: [ALL]
{{- end -}}

{{- define "habibi.env" -}}
{{- if .Values.platform.enabled }}
- name: DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: {{ .Release.Name }}-postgres-app
      key: uri
- name: SECRET_KEY_BASE
  valueFrom:
    secretKeyRef:
      name: {{ .Release.Name }}-secret-key-base
      key: SECRET_KEY_BASE
- name: RELEASE_COOKIE
  valueFrom:
    secretKeyRef:
      name: {{ .Release.Name }}-release-cookie
      key: RELEASE_COOKIE
{{- end }}
{{- if or .Values.platform.enabled .Values.external.databaseCASecret }}
- name: DATABASE_CA_CERT
  value: /database/ca.crt
{{- end }}
- name: POD_IP
  valueFrom:
    fieldRef:
      fieldPath: status.podIP
- name: RELEASE_TMP
  value: /tmp
- name: ERL_CRASH_DUMP
  value: /tmp/erl_crash.dump
- name: ERL_FLAGS
  value: "+S 2:2 -kernel inet_dist_listen_min 9100 inet_dist_listen_max 9100"
- name: POOL_SIZE
  value: {{ .Values.poolSize | quote }}
{{- end -}}
