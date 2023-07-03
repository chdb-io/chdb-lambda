FROM public.ecr.aws/lambda/python:latest

COPY requirements.txt ./
COPY lambda.py ./

RUN python3 -m pip install -r requirements.txt

ENV AWS_ACCESS_KEY_ID 000
ENV AWS_SECRET_ACCESS_KEY 000
ENV AWS_SESSION_TOKEN 000

CMD ["lambda.lambda_handler"]
