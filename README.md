# EMQX

[![GitHub Release](https://img.shields.io/github/release/emqx/emqx?color=brightgreen&label=Release)](https://github.com/emqx/emqx/releases)
[![Build Status](https://github.com/emqx/emqx/actions/workflows/run_test_cases.yaml/badge.svg)](https://github.com/emqx/emqx/actions/workflows/run_test_cases.yaml)
[![Coverage Status](https://img.shields.io/coveralls/github/emqx/emqx/master?label=Coverage)](https://coveralls.io/github/emqx/emqx?branch=master)
[![Docker Pulls](https://img.shields.io/docker/pulls/emqx/emqx?label=Docker%20Pulls)](https://hub.docker.com/r/emqx/emqx)
[![Slack](https://img.shields.io/badge/Slack-EMQ-39AE85?logo=slack)](https://slack-invite.emqx.io/)
[![Discord](https://img.shields.io/discord/931086341838622751?label=Discord&logo=discord)](https://discord.gg/xYGf3fQnES)
[![Twitter](https://img.shields.io/badge/Follow-EMQ-1DA1F2?logo=twitter)](https://twitter.com/EMQTech)
[![YouTube](https://img.shields.io/badge/Subscribe-EMQ-FF0000?logo=youtube)](https://www.youtube.com/channel/UC5FjR77ErAxvZENEWzQaO5Q)


EMQX is the world's most scalable open-source MQTT broker with a high performance that connects 100M+ IoT devices in 1 cluster, while maintaining 1M message per second throughput and sub-millisecond latency.

EMQX supports multiple open standard protocols like MQTT, HTTP, QUIC, and WebSocket. It’s 100% compliant with MQTT 5.0 and 3.x standard, and secures bi-directional communication with MQTT over TLS/SSL and various authentication mechanisms.

With the built-in powerful SQL-based [rules engine](https://www.emqx.com/en/solutions/iot-rule-engine), EMQX can extract, filter, enrich and transform IoT data in real-time. In addition, it ensures high availability and horizontal scalability with a masterless distributed architecture, and provides ops-friendly user experience and great observability.

EMQX boasts more than 20K+ enterprise users across 50+ countries and regions, connecting 100M+ IoT devices worldwide, and is trusted by over 400 customers in mission-critical scenarios of IoT, IIoT, connected vehicles, and more, including over 70 Fortune 500 companies like HPE, VMware, Verifone, SAIC Volkswagen, and Ericsson.

For more information, please visit [EMQX homepage](https://www.emqx.io/).

## Get Started

#### Run EMQX in the Cloud

The simplest way to set up EMQX is to create a managed deployment with EMQX Cloud. You can [try EMQX Cloud for free](https://www.emqx.com/en/signup?utm_source=github.com&utm_medium=referral&utm_campaign=emqx-readme-to-cloud&continue=https://cloud-intl.emqx.com/console/deployments/0?oper=new), no credit card required.

#### Run EMQX using Docker

```
docker run -d --name emqx -p 1883:1883 -p 8083:8083 -p 8084:8084 -p 8883:8883 -p 18083:18083 emqx/emqx:latest
```

Next, please follow the [getting started guide](https://www.emqx.io/docs/en/v5.0/getting-started/getting-started.html#start-emqx) to tour the EMQX features.

#### Run EMQX cluster on kubernetes

For details: [EMQX Operator](https://github.com/emqx/emqx-operator/blob/main/docs/en_US/getting-started/getting-started.md).

#### More installation options

If you prefer to install and manage EMQX yourself, you can download the latest version from [www.emqx.io/downloads](https://www.emqx.io/downloads).

For more installation options, see the [EMQX installation documentation](https://www.emqx.io/docs/en/v5.0/deploy/install.html).

## Documentation

The EMQX documentation is available at [www.emqx.io/docs/en/latest/](https://www.emqx.io/docs/en/latest/).

The EMQX Enterprise documentation is available at [docs.emqx.com/en/](https://docs.emqx.com/en/).

## Contributing

Please see our [contributing.md](./CONTRIBUTING.md).

For more organised improvement proposals, you can send pull requests to [EIP](https://github.com/emqx/eip).

## Get Involved

- Follow [@EMQTech on Twitter](https://twitter.com/EMQTech).
- Join our [Slack](https://slack-invite.emqx.io/).
- If you have a specific question, check out our [discussion forums](https://github.com/emqx/emqx/discussions).
- For general discussions, join us on the [official Discord](https://discord.gg/xYGf3fQnES) team.
- Keep updated on [EMQX YouTube](https://www.youtube.com/channel/UC5FjR77ErAxvZENEWzQaO5Q) by subscribing.

## Resources

- [MQTT client programming](https://www.emqx.com/en/blog/tag/mqtt-client-programming)

  A series of blogs to help developers get started quickly with MQTT in PHP, Node.js, Python, Golang, and other programming languages.

- [MQTT SDKs](https://www.emqx.com/en/mqtt-client-sdk)

  We have selected popular MQTT client SDKs in various programming languages and provided code examples to help you quickly understand the use of MQTT clients.

- [MQTTX](https://mqttx.app/)

  An elegant cross-platform MQTT 5.0 client tool that provides desktop, command line, and web to help you develop and debug MQTT services and applications faster.

- [Internet of Vehicles](https://www.emqx.com/en/blog/category/internet-of-vehicles)

  Build a reliable, efficient, and industry-specific IoV platform based on EMQ's practical experience, from theoretical knowledge such as protocol selection to practical operations like platform architecture design.

## Build From Source

The `master` branch is for the latest version 5 release, checkout `main-v4.4` for version 4.4.

EMQX requires OTP 24 for 4.4, 5.0 can be built with OTP 24 or 25.

```bash
git clone https://github.com/emqx/emqx.git
cd emqx
make
_build/emqx/rel/emqx/bin/emqx console
```

For 4.2 or earlier versions, release has to be built from another repo.

```bash
git clone https://github.com/emqx/emqx-rel.git
cd emqx-rel
make
_build/emqx/rel/emqx/bin/emqx console
```

## License

See [LICENSE](./LICENSE).
