FROM httpd:2.4

COPY conf/ /usr/local/apache2/conf/
COPY data/ /data/

# alice/secret for both schemes. The digest file is user:realm:MD5(user:realm:pass);
# htdigest wants a terminal, so the hash is computed directly.
RUN htpasswd -bc /usr/local/apache2/conf/basic.passwd alice secret \
 && printf 'alice:rclone-test:%s\n' \
      "$(printf 'alice:rclone-test:secret' | md5sum | cut -d' ' -f1)" \
      > /usr/local/apache2/conf/digest.passwd \
 && chown -R daemon:daemon /data && chmod -R u+rwX /data

# Each service picks its variant with -f, e.g.
#   httpd -f /usr/local/apache2/conf/digest.conf -D FOREGROUND
CMD ["httpd", "-f", "/usr/local/apache2/conf/open.conf", "-D", "FOREGROUND"]
