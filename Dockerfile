FROM python:3.12-alpine

RUN apk add --no-cache bash curl jq

WORKDIR /workspace
COPY delete_all_agents.sh housekeeping.sh ./
COPY tests ./tests
RUN chmod +x delete_all_agents.sh housekeeping.sh tests/run_tests.sh tests/mock_cursor_api.py

CMD ["./tests/run_tests.sh"]
