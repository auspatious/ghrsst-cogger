# GHRSST Cogger and Lambda Function

## Cost calculation

Lambda costs `0.0000133334` per GB second. We're running with `10 GB` of memory. Each
job takes around 5 minutes, and there's around 10,000 jobs. So we have a total cost
of `10000 * 0.0000133334 * 10 * 5 * 60` which is `$400`.

## Infra deployment

Create a secret on AWS for the Earthdata variable.

```bash
aws secretsmanager create-secret \
    --name earthdata-token \
    --secret-string longsecretgoeshere \
    --region us-west-2
```

## Notes on GitHUb Actions

Should set up a Terraform process to create the ECR and use OIDC for auth.

See this [howto](https://blog.tedivm.com/guides/2021/10/github-actions-push-to-aws-ecr-without-credentials-oidc/).
