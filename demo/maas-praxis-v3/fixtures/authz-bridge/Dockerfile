FROM golang:1.23 AS build
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download
COPY main.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /out/authz-bridge .
FROM gcr.io/distroless/static:nonroot
COPY --from=build /out/authz-bridge /authz-bridge
USER nonroot:nonroot
ENTRYPOINT ["/authz-bridge"]
