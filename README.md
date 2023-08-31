<img src="https://avatars.githubusercontent.com/u/132536224" width=300 >

# chDB in AWS Lambda

> Running chdb in a lambda container function 

This sample shows how to run the chdb OLAP engine in an AWS Lambda function to enable ad-hoc querying of any cloud dataset with ClickHouse SQL using a simple HTTP client, without the need to run or deploy a ClickHouse cluster or dedicated cloud service.

![chdb-lambda)](https://github.com/chdb-io/chdb-lambda/assets/1423657/0d6f9cf9-f8ad-47d9-95ea-638d2170335a)


## Create an AWS Lambda Function for chDB

➡ **Build & Push** the latest [chDB-lambda container](https://github.com/chdb-io/chdb-server/tree/main/lambda) image to your **ECR** storage.

### Upload Docker image on ECR and Lambda
Lambda function continers must be hosted on the AWS Elastic Container Registry.<br>
Before proceeding authenticate into your AWS console.

1. Export your AWS account id in the shell or better yet, add it your ~/.bashrc or ~/.bash_profile 
```
$ export AWS_ACCOUNT_ID = <account_id>
```

2. Install the AWS CLI and configure with your AWS credentials
```
$ aws configure
```

3. Review and execute the ‘deploy.sh’ script:
```
$ ./deploy.sh
```



➡ Search for **AWS Lambda** and select the service. Then, click **Create Function**.

<img src="https://images.ctfassets.net/o7xu9whrs0u9/5XE0x5uBoOA4oJYZFwzNea/79493c8495c8d60c726cfeeae73a2b84/create_function.png" align="left">

<br>

<br>

➡ Choose **Container Image** and use the **chDB ECR** instance URI you created

<img src="https://user-images.githubusercontent.com/1423657/250210923-887894c3-35ef-4083-a4b8-29d247f1fc1c.png" align="left">


<br>

<br>

➡ Click **Create Function** at the bottom right when you’re done.

<br>

### Validation

Let's **test** our new **chDB Lambda** using a *simple query.*

The Lamba expects JSON POST requests with a **query** key:


```bash
curl -XPOST "http://{lambda_url}/query" \
  --header 'Content-Type: application/json'
  --data '{"query": "SELECT version()", "default_format": "CSV"}'
```

And the response would look like this (or any other format)

```plaintext
23.6.1.1
```

You can also use the Browser and the AWS Console to generate **test events**:

<img src="https://user-images.githubusercontent.com/1423657/250201531-daa26b0b-68e2-4cec-b665-5505efe99b99.png" align="left">

<br>

<br>

-----

