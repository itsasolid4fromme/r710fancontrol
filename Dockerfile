FROM alpine:3.21
RUN apk add --no-cache bash ipmitool python3 tzdata
COPY r710-fan.sh /usr/local/bin/r710-fan
COPY tools/calibrate.sh /usr/local/bin/r710-calibrate
COPY web/ /usr/local/share/r710-fan/web/
RUN chmod 755 /usr/local/bin/r710-fan /usr/local/bin/r710-calibrate \
 && ln -s r710-fan /usr/local/bin/fanctl
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
ENTRYPOINT ["r710-fan"]
CMD ["daemon"]
