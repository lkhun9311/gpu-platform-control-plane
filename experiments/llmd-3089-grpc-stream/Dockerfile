FROM golang:1.25 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY backend backend
COPY client client
RUN CGO_ENABLED=0 go build -o /out/backend ./backend && CGO_ENABLED=0 go build -o /out/client ./client

FROM gcr.io/distroless/static:nonroot
COPY --from=build /out/backend /out/client /usr/local/bin/
ENTRYPOINT ["/usr/local/bin/backend"]
