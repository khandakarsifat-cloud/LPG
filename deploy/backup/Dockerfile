FROM public.ecr.aws/supabase/postgres:17.6.1.140
# Keep the exact PostgreSQL binaries/extensions; add only the backup client.
USER root
RUN apk add --no-cache pgbackrest=2.57.0-r0
