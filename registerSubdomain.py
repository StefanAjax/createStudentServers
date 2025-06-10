#!/usr/local/bin/python  
# -*- coding: utf-8 -*-  
  
import sys  
import time  
import xmlrpc.client
import os
from dotenv import load_dotenv
  
def main():  
    load_dotenv()
    
    global_api_username = os.getenv('DNS_API_USER')
    global_api_password = os.getenv('DNS_API_PASS')
    school_ip_address = os.getenv('SCHOOL_IP_ADDRESS')
    global_dns_uri = os.getenv('DNS_API_URI')
    domain_suffix = os.getenv('DOMAIN_SUFFIX')

    subdomain = sys.argv[1]
    
    client = xmlrpc.client.ServerProxy(uri = global_dns_uri, encoding = 'utf-8')  
    response = client.addSubdomain(global_api_username, global_api_password, domain, subdomain)
    # print(response)
    time.sleep(1)
    record_obj = {'type' : 'A',  
            'ttl' : 3600,
            'priority' : 1,
            'rdata' : school_ip_address,
            'record_id' : 10,
            }
    response = client.addZoneRecord(global_api_username, global_api_password, domain, subdomain, record_obj)
    # print(response)
  
if __name__ == '__main__':  
    main()  
  