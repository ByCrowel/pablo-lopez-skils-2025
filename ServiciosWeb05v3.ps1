param(
    [string]$Nombre = "Web05v3"
)

$outputFile = "ServiciosWeb05-output.txt"
if (Test-Path $outputFile) { Remove-Item $outputFile }

function Escribir-Salida {
    param([string]$texto)
    $texto | Out-File -FilePath $outputFile -Append
    Write-Host $texto
}

function Wait-ForInstanceRunning {
    param([string]$InstanceId)
    $state = ""
    while ($state -ne "running") {
        Write-Host "Esperando que la instancia $InstanceId esté en estado 'running'..."
        Start-Sleep -Seconds 10
        $state = aws ec2 describe-instances --instance-ids $InstanceId --region $Region --query "Reservations[0].Instances[0].State.Name" --output text
    }
    Write-Host "La instancia $InstanceId está corriendo."
}

# Variables
$VPC_CIDR = "172.20.0.0/16"
$Subnet_CIDR = "172.20.140.0/26"
$Region = "us-east-1"
$KeyName = "vockey"
$InstanceType = "t3.micro"
$UbuntuAMI = "ami-084568db4383264d4"
$WindowsAMI = "ami-02e3d076cbd5c28fa"

# Crear VPC
$vpcId = aws ec2 create-vpc --cidr-block $VPC_CIDR --region $Region --query 'Vpc.VpcId' --output text
aws ec2 create-tags --resources $vpcId --tags Key=Name,Value=$Nombre --region $Region
Escribir-Salida "VPC creada: ID = $vpcId"

# Crear Subred pública
$subnetId = aws ec2 create-subnet --vpc-id $vpcId --cidr-block $Subnet_CIDR --availability-zone "${Region}a" --region $Region --query 'Subnet.SubnetId' --output text
aws ec2 create-tags --resources $subnetId --tags Key=Name,Value=$Nombre --region $Region
Escribir-Salida "Subred pública creada: ID = $subnetId"

# Crear Internet Gateway
$igwId = aws ec2 create-internet-gateway --region $Region --query 'InternetGateway.InternetGatewayId' --output text
aws ec2 attach-internet-gateway --vpc-id $vpcId --internet-gateway-id $igwId --region $Region
aws ec2 create-tags --resources $igwId --tags Key=Name,Value=$Nombre --region $Region
Escribir-Salida "Internet Gateway creado: ID = $igwId"

# Crear tabla de rutas y asociar a la subred
$routeTableId = aws ec2 create-route-table --vpc-id $vpcId --region $Region --query 'RouteTable.RouteTableId' --output text
aws ec2 create-route --route-table-id $routeTableId --destination-cidr-block 0.0.0.0/0 --gateway-id $igwId --region $Region
aws ec2 associate-route-table --subnet-id $subnetId --route-table-id $routeTableId --region $Region
Escribir-Salida "Tabla de rutas creada y asociada: ID = $routeTableId"

# Crear grupo de seguridad
$sgId = aws ec2 create-security-group --group-name "${Nombre}_SG" --description "SG para Web05" --vpc-id $vpcId --region $Region --query 'GroupId' --output text
aws ec2 authorize-security-group-ingress --group-id $sgId --protocol tcp --port 22 --cidr 0.0.0.0/0 --region $Region
aws ec2 authorize-security-group-ingress --group-id $sgId --protocol tcp --port 80 --cidr 0.0.0.0/0 --region $Region
aws ec2 authorize-security-group-ingress --group-id $sgId --protocol tcp --port 3389 --cidr 0.0.0.0/0 --region $Region
aws ec2 create-tags --resources $sgId --tags Key=Name,Value=$Nombre --region $Region
Escribir-Salida "Grupo de seguridad creado: ID = $sgId"

# Crear IPs elásticas
$eipUbuntu = aws ec2 allocate-address --region $Region --query 'AllocationId' --output text
$eipWindows = aws ec2 allocate-address --region $Region --query 'AllocationId' --output text
Escribir-Salida "Elastic IPs reservadas: Ubuntu = $eipUbuntu, Windows = $eipWindows"

# Lanzar EC2 Ubuntu con NGINX
$ubuntuUserData = @"
#!/bin/bash
sudo apt update -y
sudo apt install nginx -y
sudo systemctl start nginx
sudo systemctl enable nginx
"@

$ubuntuInstanceId = aws ec2 run-instances `
    --image-id $UbuntuAMI `
    --count 1 `
    --instance-type $InstanceType `
    --key-name $KeyName `
    --security-group-ids $sgId `
    --subnet-id $subnetId `
    --associate-public-ip-address `
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$Nombre-Ubuntu}]" `
    --user-data "$ubuntuUserData" `
    --region $Region `
    --query 'Instances[0].InstanceId' --output text

Escribir-Salida "EC2 Ubuntu creada: ID = $ubuntuInstanceId"
Wait-ForInstanceRunning -InstanceId $ubuntuInstanceId

aws ec2 associate-address --instance-id $ubuntuInstanceId --allocation-id $eipUbuntu --region $Region
Escribir-Salida "Elastic IP asociada a Ubuntu: ID de instancia = $ubuntuInstanceId"

# Lanzar EC2 Windows con IIS
$windowsUserData = @"
<powershell>
Install-WindowsFeature -Name Web-Server
Start-Service W3SVC
</powershell>
"@

$windowsInstanceId = aws ec2 run-instances `
    --image-id $WindowsAMI `
    --count 1 `
    --instance-type $InstanceType `
    --key-name $KeyName `
    --security-group-ids $sgId `
    --subnet-id $subnetId `
    --associate-public-ip-address `
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$Nombre-Windows}]" `
    --user-data "$windowsUserData" `
    --region $Region `
    --query 'Instances[0].InstanceId' --output text

Escribir-Salida "EC2 Windows creada: ID = $windowsInstanceId"
Wait-ForInstanceRunning -InstanceId $windowsInstanceId

aws ec2 associate-address --instance-id $windowsInstanceId --allocation-id $eipWindows --region $Region
Escribir-Salida "Elastic IP asociada a Windows: ID de instancia = $windowsInstanceId"

Escribir-Salida "`n✅ Todos los recursos fueron creados correctamente."
