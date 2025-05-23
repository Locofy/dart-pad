ARG GCP_PROJECT_ID
ARG BASE_IMAGE_REPOSITORY
ARG COMMIT_HASH
ARG FLUTTER_CHANNEL=stable

FROM asia-southeast1-docker.pkg.dev/$BASE_IMAGE_REPOSITORY:$FLUTTER_CHANNEL

RUN adduser --disabled-password --uid 443 --gecos '' flutter
RUN adduser flutter sudo
RUN echo '%sudo ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers

WORKDIR /pkgs/dartpad_shared
COPY pkgs/dartpad_shared .

WORKDIR /pkgs/dart_services
COPY pkgs/dart_services .

RUN chown -R flutter /opt /pkgs/dartpad_shared /pkgs/dart_services

USER 443

RUN dart pub get
RUN dart compile exe bin/server.dart -o bin/server

RUN dart run grinder update-pub-dependencies

RUN dart run grinder build-project-templates
RUN cd project_templates/dart_project && dart pub get && dart pub upgrade
RUN cd project_templates/flutter_project && dart pub get && dart pub upgrade

RUN dart run grinder build-storage-artifacts

RUN sed -i '20s|url: '\''assets/no_sleep.js'\'', flutterPluginName: '\''wakelock_plus'\''|url: '\''https://static.locofy.ai/libs/flutter/no_sleep.js'\'', flutterPluginName: '\''wakelock_plus'\''|' "/home/flutter/.pub-cache/hosted/pub.dev/wakelock_plus-1.2.10/lib/src/wakelock_plus_web_plugin.dart"
RUN sed -i "s|'assets/packages/media_kit/assets/web/hls1.4.10.js';|'https://static.locofy.ai/libs/flutter/hls1.4.10.js';|" "/home/flutter/.pub-cache/hosted/pub.dev/media_kit-1.1.11/lib/src/player/web/utils/hls.dart"

ENV COMMIT_HASH=${COMMIT_HASH}

EXPOSE 8080

# Override the ENTRYPOINT to disable `flutter`
ENTRYPOINT []

# Set the default command
CMD ["/pkgs/dart_services/bin/server"]
