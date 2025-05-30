provider "aws" {
    region = "us-east-1"
}

# VPC
resource "aws_vpc" "main" {
    cidr_block = "10.0.0.0/16"
    tags = {
        Name = "main-vpc"
    }
}

# Public Subnet
resource "aws_subnet" "public" {
    vpc_id                  = aws_vpc.main.id
    cidr_block              = "10.0.1.0/24"
    map_public_ip_on_launch = true
    availability_zone       = "us-east-1a"
    tags = {
        Name = "public-subnet"
    }
}

# Private Subnet
resource "aws_subnet" "private" {
    vpc_id            = aws_vpc.main.id
    cidr_block        = "10.0.2.0/24"
    availability_zone = "us-east-1a"
    tags = {
        Name = "private-subnet"
    }
}

# Internet Gateway
resource "aws_internet_gateway" "gw" {
    vpc_id = aws_vpc.main.id
    tags = {
        Name = "main-igw"
    }
}

# Public Route Table
resource "aws_route_table" "public" {
    vpc_id = aws_vpc.main.id
    route {
        cidr_block = "0.0.0.0/0"
        gateway_id = aws_internet_gateway.gw.id
    }
    tags = {
        Name = "public-rt"
    }
}

resource "aws_route_table_association" "public" {
    subnet_id      = aws_subnet.public.id
    route_table_id = aws_route_table.public.id
}

# NAT Gateway EIP
resource "aws_eip" "nat" {
    vpc = true
}

# NAT Gateway
resource "aws_nat_gateway" "nat" {
    allocation_id = aws_eip.nat.id
    subnet_id     = aws_subnet.public.id
    tags = {
        Name = "main-nat"
    }
}

# Private Route Table
resource "aws_route_table" "private" {
    vpc_id = aws_vpc.main.id
    route {
        cidr_block     = "0.0.0.0/0"
        nat_gateway_id = aws_nat_gateway.nat.id
    }
    tags = {
        Name = "private-rt"
    }
}

resource "aws_route_table_association" "private" {
    subnet_id      = aws_subnet.private.id
    route_table_id = aws_route_table.private.id
}

# Example EC2 instance in public subnet
resource "aws_instance" "example" {
    ami           = "ami-0c94855ba95c71c99"
    instance_type = "t2.micro"
    subnet_id     = aws_subnet.public.id

    tags = {
        Name = "ExampleEC2"
    }
}
# IAM Role for EC2
resource "aws_iam_role" "ec2_role" {
    name = "ec2-role"
    assume_role_policy = jsonencode({
        Version = "2012-10-17",
        Statement = [{
            Action = "sts:AssumeRole",
            Effect = "Allow",
            Principal = {
                Service = "ec2.amazonaws.com"
            }
        }]
    })
    tags = {
        Name = "ec2-role"
    }
}

# IAM Policy Attachment (AmazonEC2ReadOnlyAccess as example)
resource "aws_iam_role_policy_attachment" "ec2_readonly" {
    role       = aws_iam_role.ec2_role.name
    policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ReadOnlyAccess"
}

# IAM Instance Profile
resource "aws_iam_instance_profile" "ec2_profile" {
    name = "ec2-instance-profile"
    role = aws_iam_role.ec2_role.name
}
# ECR Repository for container images
resource "aws_ecr_repository" "app_repo" {
    name = "app-container-repo"
    image_tag_mutability = "MUTABLE"
    image_scanning_configuration {
        scan_on_push = true
    }
    tags = {
        Name = "app-container-repo"
    }
}

# Lambda Function Role
resource "aws_iam_role" "lambda_role" {
    name = "lambda-exec-role"
    assume_role_policy = jsonencode({
        Version = "2012-10-17",
        Statement = [{
            Action = "sts:AssumeRole",
            Effect = "Allow",
            Principal = {
                Service = "lambda.amazonaws.com"
            }
        }]
    })
    tags = {
        Name = "lambda-exec-role"
    }
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
    role       = aws_iam_role.lambda_role.name
    policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Lambda Function
resource "aws_lambda_function" "api_handler" {
    function_name = "api-handler"
    role          = aws_iam_role.lambda_role.arn
    handler       = "index.handler"
    runtime       = "nodejs18.x"

    filename         = "lambda_function_payload.zip"
    source_code_hash = filebase64sha256("lambda_function_payload.zip")

    tags = {
        Name = "api-handler"
    }
}

# API Gateway REST API
resource "aws_api_gateway_rest_api" "api" {
    name        = "lambda-api"
    description = "API Gateway to trigger Lambda"
}

resource "aws_api_gateway_resource" "proxy" {
    rest_api_id = aws_api_gateway_rest_api.api.id
    parent_id   = aws_api_gateway_rest_api.api.root_resource_id
    path_part   = "invoke"
}

resource "aws_api_gateway_method" "proxy_method" {
    rest_api_id   = aws_api_gateway_rest_api.api.id
    resource_id   = aws_api_gateway_resource.proxy.id
    http_method   = "POST"
    authorization = "NONE"
}

resource "aws_api_gateway_integration" "lambda_integration" {
    rest_api_id = aws_api_gateway_rest_api.api.id
    resource_id = aws_api_gateway_resource.proxy.id
    http_method = aws_api_gateway_method.proxy_method.http_method

    integration_http_method = "POST"
    type                    = "AWS_PROXY"
    uri                     = aws_lambda_function.api_handler.invoke_arn
}

resource "aws_lambda_permission" "apigw" {
    statement_id  = "AllowAPIGatewayInvoke"
    action        = "lambda:InvokeFunction"
    function_name = aws_lambda_function.api_handler.function_name
    principal     = "apigateway.amazonaws.com"
    source_arn    = "${aws_api_gateway_rest_api.api.execution_arn}/*/*"
}

resource "aws_api_gateway_deployment" "api_deployment" {
    depends_on = [aws_api_gateway_integration.lambda_integration]
    rest_api_id = aws_api_gateway_rest_api.api.id
    stage_name  = "prod"
}