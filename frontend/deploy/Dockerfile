# The web app as a container for ECS: nginx serves the Flutter build and
# forwards the API paths to the backend, so the browser sees one origin.
# That keeps the auth cookies first-party (SameSite=Lax works) and lets the
# API's CORS_ORIGINS stay empty.
#
# Build from frontend/ after `flutter build web --release
# --dart-define-from-file=env/prod.json.example` (API_BASE_URL empty, so the
# app calls its own origin):
#
#   docker buildx build --platform linux/amd64 -f deploy/Dockerfile -t <repo>:<tag> .
#
# Express Mode runs x86_64, hence linux/amd64.
#
# Runtime environment:
#   API_ORIGIN  scheme://host of the API, e.g. https://xxxx.ecs.ap-south-1.on.aws
#   API_HOST    the host part alone (Host header and TLS SNI for the API's ALB)
FROM public.ecr.aws/docker/library/nginx:1.27-alpine

# The image's entrypoint renders /etc/nginx/templates/*.template with
# envsubst (only variables that are set, so nginx's own $vars survive) and,
# with this flag, exports the container's DNS servers as
# NGINX_LOCAL_RESOLVERS for the resolver directive.
ENV NGINX_ENTRYPOINT_LOCAL_RESOLVERS=1

# Rendered over the stock conf.d/default.conf at start. No RUN steps, so
# the amd64 image builds on any host without emulation.
COPY deploy/nginx.conf.template /etc/nginx/templates/default.conf.template
COPY build/web /usr/share/nginx/html

EXPOSE 8080
