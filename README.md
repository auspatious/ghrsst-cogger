# GHRSST Cogger and Lambda Function

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
