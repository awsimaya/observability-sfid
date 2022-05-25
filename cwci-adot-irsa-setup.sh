#!/bin/bash -e
CLUSTER_NAME=PetSite
SERVICE_ACCOUNT_ADOT_NAMESPACE=amazon-metrics
SERVICE_ACCOUNT_FLUENTBIT_NAMESPACE=amazon-cloudwatch
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
OIDC_PROVIDER=$(aws eks describe-cluster --name $CLUSTER_NAME --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///")
SERVICE_ACCOUNT_NAME=adot-collector-sa
SERVICE_ACCOUNT_FLUENTBIT_NAME=fluent-bit
SERVICE_ACCOUNT_IAM_ROLE=EKS-ADOT-CWCI-Helm-Chart-Role
SERVICE_ACCOUNT_IAM_POLICY=EKS-ADOT-CWCI-Helm-Chart-Policy
#
# Set up a trust policy designed for a specific combination of K8s service account and namespace to sign in from a Kubernetes cluster which hosts the OIDC Idp.
#
cat <<EOF > ADOT_TrustPolicy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:${SERVICE_ACCOUNT_ADOT_NAMESPACE}:${SERVICE_ACCOUNT_NAME}"
        }
      }
    },
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
            "${OIDC_PROVIDER}:sub": "system:serviceaccount:${SERVICE_ACCOUNT_FLUENTBIT_NAMESPACE}:${SERVICE_ACCOUNT_FLUENTBIT_NAME}"
        }
      }
    }
  ]
}
EOF


function getRoleArn() {
  OUTPUT=$(aws iam get-role --role-name $1 --query 'Role.Arn' --output text 2>&1)

  # Check for an expected exception
  if [[ $? -eq 0 ]]; then
    echo $OUTPUT
  elif [[ -n $(grep "NoSuchEntity" <<< $OUTPUT) ]]; then
    echo ""
  else
    >&2 echo $OUTPUT
    return 1
  fi
}

#
# Create the IAM Role for ingest with the above trust policy
#
SERVICE_ACCOUNT_IAM_ROLE_ARN=$(getRoleArn $SERVICE_ACCOUNT_IAM_ROLE)
if [ "$SERVICE_ACCOUNT_IAM_ROLE_ARN" = "" ]; 
then
  #
  # Create the IAM role for service account
  #
  SERVICE_ACCOUNT_IAM_ROLE_ARN=$(aws iam create-role \
  --role-name $SERVICE_ACCOUNT_IAM_ROLE \
  --assume-role-policy-document file://ADOT_TrustPolicy.json \
  --query "Role.Arn" --output text)
  
  # Attach managed policy to ingest metrics into AMP
  aws iam attach-role-policy \
  --role-name $SERVICE_ACCOUNT_IAM_ROLE \
  --policy-arn "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"

else
    echo "$SERVICE_ACCOUNT_IAM_ROLE_ARN IAM role for ingest already exists"
fi
echo $SERVICE_ACCOUNT_IAM_ROLE_ARN
#
# EKS cluster hosts an OIDC provider with a public discovery endpoint.
# Associate this IdP with AWS IAM so that the latter can validate and accept the OIDC tokens issued by Kubernetes to service accounts.
# Doing this with eksctl is the easier and best approach.
#
# eksctl utils associate-iam-oidc-provider --cluster $CLUSTER_NAME --approve