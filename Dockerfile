FROM jookies/jasmin

RUN pip install --upgrade pip && \
    pip install fastapi uvicorn requests

COPY api/ api/

WORKDIR /api

COPY config/ /opt/myfiles/

EXPOSE 2775 1401 8990

CMD ["sh", "-c", "/entrypoint.sh & uvicorn main:app --host 0.0.0.0 --port 8000"]