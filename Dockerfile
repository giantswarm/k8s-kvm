FROM golang:1.15-alpine AS build

WORKDIR /usr/src/app

COPY go.mod .
COPY go.sum .

RUN go mod download

COPY . .

RUN CGO_ENABLED=0 GOOS=linux go build -o ./bin/k8s-kvm ./cmd/main.go

FROM fedora:33

RUN dnf -y update \
    && dnf -y install qemu-system-x86 xfsprogs net-tools \
    && dnf clean all

COPY --from=build /usr/src/app/bin /usr/local/bin

ENTRYPOINT ["k8s-kvm"]
