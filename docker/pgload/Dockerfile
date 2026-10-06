# syntax=docker/dockerfile:1.7
FROM golang:1.27.0-bookworm AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY main.go ./
RUN CGO_ENABLED=0 go build -trimpath -o /pgload .

FROM scratch
COPY --from=build /pgload /pgload
ENTRYPOINT ["/pgload"]
