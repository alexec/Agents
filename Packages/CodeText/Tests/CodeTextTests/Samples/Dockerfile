# A small shop's till, for the colour samples (041).
FROM swift:6.2-jammy AS build
ARG VERSION=1.4.0
WORKDIR /src
COPY Package.swift ./
RUN swift package resolve && \
    echo "resolved ${VERSION}"
COPY . .
RUN swift build -c release

FROM ubuntu:24.04
ENV TILL_FLOAT=150 \
    TILL_MASK=0xFF
COPY --from=build /src/.build/release/till /usr/local/bin/till
EXPOSE 8080
ENTRYPOINT ["till", "--serve"]
