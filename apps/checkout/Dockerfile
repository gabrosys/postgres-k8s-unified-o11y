ARG GO_IMAGE
ARG RUNTIME_IMAGE

FROM ${GO_IMAGE} AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /checkout .

FROM ${RUNTIME_IMAGE}
COPY --from=build /checkout /checkout
USER nonroot:nonroot
ENTRYPOINT ["/checkout"]
