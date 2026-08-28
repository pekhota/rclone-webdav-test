# rclone-webdav-test

WebDAV servers in Docker for testing rclone's webdav backend, with a smoke test
that runs the same set of operations against every one of them.

Rclone's own integration remotes (`TestWebdavNextcloud:`, `TestWebdavOwncloud:`,
`TestWebdavRclone:`) all authenticate with basic auth, so nothing in `test_all`
exercises digest, stale nonces, or a server offering an algorithm rclone can't
sign with. That is the gap this fills.

## Layout

Clone this inside an rclone checkout, so the code you are working on is what
gets tested:

```
rclone/                     your rclone checkout
└── rclone-webdav-test/     this repo
    ├── smoke.sh            rebuilds ../ before each run
    └── .rclone-built       the binary it builds (gitignored)
```

```console
git clone <this repo> rclone-webdav-test
cd rclone-webdav-test
docker compose up -d --build
./smoke.sh
```

Inside an rclone checkout the script rebuilds rclone from source on every run,
into `.rclone-built`, so results always describe the working tree and never a
stale binary. That costs 10-20s, nearly all of it linking, against a run
measured in minutes. `SKIP_BUILD=1 ./smoke.sh` reuses the last build.

It never uses `go run`, which costs about 6s per invocation against 0.2s for a
binary - with a few hundred calls per run that would add half an hour.

A build without digest support is not refused: it prints a warning and runs
anyway, so the digest remotes fail and everything else passes. That is what
makes before and after comparisons work:

```console
git -C .. switch master   && ./smoke.sh   # 73 passed, 5 failed
git -C .. switch my-branch && ./smoke.sh  # 130 passed, 0 failed
```

To test some other binary instead, and skip building entirely:
`./smoke.sh /path/to/rclone` or `RCLONE=/path/to/rclone ./smoke.sh`.

## The servers

`docker compose up -d --build` starts seven, all `alice` / `secret`:

| port  | remote                | what it is                                          |
|-------|-----------------------|-----------------------------------------------------|
| 18100 | `dav-open`            | no authentication, the control case                  |
| 18101 | `dav-basic`           | Apache, basic auth                                   |
| 18102 | `dav-rclone`          | `rclone serve webdav`, a second basic implementation |
| 18103 | `dav-digest`          | Apache, digest auth                                  |
| 18104 | `dav-digest-stale`    | digest, 5s nonce lifetime, so challenges go stale    |
| 18105 | `dav-digest-nccheck`  | digest with `AuthDigestNcCheck On`                   |
| 18106 | `dav-digest-md5sess`  | offers `algorithm=MD5-sess`, which rclone can't do   |

`dav-digest` and `dav-digest-preset` are the same server: the first lets rclone
discover digest from the 401, the second has `digest = true` set up front so no
password is ever sent using basic authentication.

Two more, behind a profile because they are large and slow to start:

```console
docker compose --profile heavy up -d      # nextcloud 18110, owncloud 18111
```

| port  | remote          | why it matters                                             |
|-------|-----------------|------------------------------------------------------------|
| 18110 | `dav-nextcloud` | sets modification times with PROPPATCH, reports quota       |
| 18111 | `dav-owncloud`  | reports quota, and the checksum quirk noted below           |

These use `alice` / `secretsecret`.

## The smoke test

`./smoke.sh` runs 16 checks against each remote: upload into a subdirectory,
upload to the remote root, twelve concurrent uploads verified with `check`,
overwrite, delete, an 8 MiB file compared byte for byte after a round trip, a
streamed `rcat` upload, server side copy and move, directory move, rmdir,
setting a modification time, quota, and purge. Then it checks that the
`MD5-sess` server is refused with a message naming the algorithm.

Some checks report `SKIP` rather than failing, where the server genuinely
doesn't offer the feature:

- **modification times** skip on plain WebDAV, which has no propset support.
  They also skip on ownCloud: rclone sends `lastmodified` and `oc:checksums` in
  one propertyupdate, ownCloud 10.16 answers `403` for the checksums, and
  WebDAV's atomicity turns that into `424 Failed Dependency` for the
  modification time. Sending `lastmodified` alone succeeds. This is not
  rclone-version specific - it reproduces on master.
- **quota** skips on Apache, whose `mod_dav_fs` doesn't implement RFC 4331.

## Adding a server

Each Apache variant is one config file plus one compose service; they all run
the same image and differ only in which config they start with.

```console
cp conf/digest.conf conf/digest-mine.conf   # edit the auth block
```

```yaml
  digest-mine:
    <<: *apache
    container_name: davlab-digest-mine
    command: ["httpd", "-f", "/usr/local/apache2/conf/digest-mine.conf", "-D", "FOREGROUND"]
    ports: ["18107:80"]
```

Then add a remote to `rclone.conf` and its name to `REMOTES` in `smoke.sh`.

## Notes

The Apache access log includes the `Authorization` header
(`auth=%{Authorization}i` in `conf/common.conf`). That is deliberate - it is how
you confirm which scheme was used, and that no password went out as basic:

```console
docker compose logs -f digest
```

Credentials in `rclone.conf` are obscured but trivially reversible, and the
servers are throwaway containers on localhost. Don't reuse these passwords.

```console
docker compose down -v      # tear everything down, volumes included
```
