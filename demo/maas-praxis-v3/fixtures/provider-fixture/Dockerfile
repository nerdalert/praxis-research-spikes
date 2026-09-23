FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -o /provider-fixture main.go
FROM alpine:3.22
COPY --from=build /provider-fixture /provider-fixture
USER 65532:65532
ENTRYPOINT ["/provider-fixture"]
