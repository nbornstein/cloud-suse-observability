resource "aws_eip" "lb_eip" {
  provider = aws.compute
  domain   = "vpc"

  tags = {
    Name = "eip-observability-lb"
  }
}

resource "aws_lb" "observability_lb" {
  provider           = aws.compute
  name               = "lb-observability-cluster"
  load_balancer_type = "network"

  subnet_mapping {
    subnet_id     = aws_subnet.subnet.id
    allocation_id = aws_eip.lb_eip.id
  }

  tags = {
    Name = "lb-observability-cluster"
  }
}

# Target groups + health checks (6443 Kube-API, 80 HTTP, 443 HTTPS).
resource "aws_lb_target_group" "tg_6443" {
  provider    = aws.compute
  name        = "observability-tg-6443"
  port        = 6443
  protocol    = "TCP"
  vpc_id      = aws_vpc.vpc.id
  target_type = "instance"

  health_check {
    protocol = "TCP"
    port     = "6443"
  }
}

resource "aws_lb_target_group" "tg_80" {
  provider    = aws.compute
  name        = "observability-tg-80"
  port        = 80
  protocol    = "TCP"
  vpc_id      = aws_vpc.vpc.id
  target_type = "instance"

  health_check {
    protocol = "TCP"
    port     = "80"
  }
}

resource "aws_lb_target_group" "tg_443" {
  provider    = aws.compute
  name        = "observability-tg-443"
  port        = 443
  protocol    = "TCP"
  vpc_id      = aws_vpc.vpc.id
  target_type = "instance"

  health_check {
    protocol = "TCP"
    port     = "443"
  }
}

resource "aws_lb_listener" "listener_6443" {
  provider          = aws.compute
  load_balancer_arn = aws_lb.observability_lb.arn
  port              = 6443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg_6443.arn
  }
}

resource "aws_lb_listener" "listener_80" {
  provider          = aws.compute
  load_balancer_arn = aws_lb.observability_lb.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg_80.arn
  }
}

resource "aws_lb_listener" "listener_443" {
  provider          = aws.compute
  load_balancer_arn = aws_lb.observability_lb.arn
  port              = 443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg_443.arn
  }
}
