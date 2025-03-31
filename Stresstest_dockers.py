import random
import hashlib
import json
import requests
import tempfile
import traceback

# Mocking the docker object and necessary functions for the example
class MockDocker:
    def __init__(self, tls_enabled, hostname, ca_cert=None, client_cert=None, client_key=None):
        self.tls_enabled = tls_enabled
        self.hostname = hostname
        self.ca_cert = ca_cert
        self.client_cert = client_cert
        self.client_key = client_key

def get_required_ports(docker, image):
    # Mock function to return required ports for the image
    return ["80/tcp"]

# Function to create a container
def create_container(docker, image, team, portbl):
    tls = docker.tls_enabled
    CERT = None
    if not tls:
        prefix = 'http'
    else:
        prefix = 'https'
        try:
            ca = docker.ca_cert
            client = docker.client_cert
            ckey = docker.client_key
            default_mode = 'w+'
            if isinstance(client, bytes):
                default_mode = 'w+b'
            ca_file = tempfile.NamedTemporaryFile(mode=default_mode, delete=False)
            ca_file.write(ca)
            ca_file.seek(0)
            client_file = tempfile.NamedTemporaryFile(mode=default_mode, delete=False)
            client_file.write(client)
            client_file.seek(0)
            key_file = tempfile.NamedTemporaryFile(mode=default_mode, delete=False)
            key_file.write(ckey)
            key_file.seek(0)
            CERT = (client_file.name, key_file.name)
        except:
            print(traceback.print_exc())
            return []
    host = docker.hostname
    URL_TEMPLATE = '%s://%s' % (prefix, host)
    needed_ports = get_required_ports(docker, image)
    team = hashlib.md5(team.encode("utf-8")).hexdigest()[:10]
    container_name = "%s_%s" % (image.split(':')[0], team)
    assigned_ports = dict()
    
    ports_list = list()
    for i in needed_ports:
        while True:
            assigned_port = random.choice(range(30000, 60000))
            if assigned_port not in portbl:
                port_protocol = i.split('/')[1]
                assigned_ports['%s/%s' % (assigned_port, port_protocol)] = {}
                ports_list.append(assigned_port)
                break
    ports = dict()
    bindings = dict()
    tmp_ports = list(assigned_ports.keys())
    for i in needed_ports:
        ports[i] = {}
        bindings[i] = [{"HostPort": tmp_ports.pop()}]
    headers = {'Content-Type': "application/json"}
    ports_list_strings = map(str, ports_list)
    env = [
        "PORTS=" + ",".join(ports_list_strings),
    ]
    data = json.dumps({"Image": image, "ExposedPorts": ports, "HostConfig": {"PortBindings": bindings, "CpuShares": 512, "Memory": 2000000000}, "Env": env})
    if tls:
        r = requests.post(url="%s/containers/create?name=%s" % (URL_TEMPLATE, container_name), cert=CERT,
                      verify=False, data=data, headers=headers)
        result = r.json()
        s = requests.post(url="%s/containers/%s/start" % (URL_TEMPLATE, result['Id']), cert=CERT, verify=False,
                          headers=headers)
    else:
        r = requests.post(url="%s/containers/create?name=%s" % (URL_TEMPLATE, container_name),
                          data=data, headers=headers)
        print(r.request.method, r.request.url, r.request.body)
        result = r.json()
        print(result)
        # name conflicts are not handled properly
        s = requests.post(url="%s/containers/%s/start" % (URL_TEMPLATE, result['Id']), headers=headers)
    return result, data

# Main script to create 50 containers
def main():
   # Load the JSON file containing team names
    with open('teams.json', 'r') as file:
        data = json.load(file)

    # Extract team names from the JSON structure
    teams = [result['name'] for result in data['results']]

    ca_cert = open("/cert/ca-cert.pem", 'r').read()
    client_cert = open("/cert/client-cert.pem", 'r').read()
    client_key = open("/cert/client-key.pem", 'r').read()
    print(ca_cert)
    docker = MockDocker(tls_enabled=True, client_cert=client_cert, ca_cert=ca_cert, client_key=client_key, hostname="172.17.0.1:2376")
    image = "httpd:latest"
    portbl = set()
    results = []

    for i in range(50):
        team = random.choice(teams)
        result, data = create_container(docker, image, team, portbl)
        if result:
            results.append(result)
            for port in data['HostConfig']['PortBindings'].values():
                portbl.add(int(port[0]['HostPort'].split('/')[0]))

    print(f"Created {len(results)} containers.")

if __name__ == "__main__":
    main()
