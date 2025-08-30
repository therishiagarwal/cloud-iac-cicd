FROM python:3.11-slim
WORKDIR /app
COPY server.py .
EXPOSE 8080
ENV APP_ENV=prod
CMD ["python", "server.py"]
