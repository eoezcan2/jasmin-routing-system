import requests
import logging

logger = logging.getLogger('jasmin-interceptor')
handler = logging.FileHandler('/var/log/jasmin/mt_interceptor.log')
formatter = logging.Formatter('%(asctime)s %(levelname)s %(message)s')
handler.setFormatter(formatter)
logger.addHandler(handler)
logger.setLevel(logging.DEBUG)

def send_message(source_addr: str, destination_addr: str, short_message: str):
    import http.client
    import json
    import ssl
    from dotenv import load_dotenv
    import os

    load_dotenv('/etc/jasmin/.env')
    API_KEY = os.getenv('API_KEY')

    # Create an SSL context that does not verify the certificate
    context = ssl._create_unverified_context()

    # Connect using the context that skips verification
    conn = http.client.HTTPSConnection("web.it-decision.com", context=context)

    payload = json.dumps({
        "phone": destination_addr,
        "sender": source_addr,
        "text": short_message,
        "validity_period": 300
    })

    headers = {
        'Authorization': f'Basic {API_KEY}',
        # <-- Replace with actual base64-encoded API key
        'Content-Type': 'application/json'
    }

    conn.request("POST", "/v1/api/send-sms", payload, headers)
    res = conn.getresponse()
    data = res.read()

    if res.status == 200:
        print("200 OK")
        print(data.decode("utf-8"))
    else:
        print(f"Error: {res.status} - {res.reason}")
        raise Exception(f"Failed to send message: {res.status} - {res.reason}")

data = {
    "source_addr": routable.pdu.params.get('source_addr', b'').decode('utf-8', errors='ignore'),
    "destination_addr": routable.pdu.params.get('destination_addr', b'').decode('utf-8', errors='ignore'),
    "short_message": routable.pdu.params.get('short_message', b'').decode('utf-8', errors='ignore')
}

try:
    logger.info(f"Sending message: {data}")
    send_message(data['source_addr'], data['destination_addr'], data['short_message'])
    logger.info("Message sent successfully")

except Exception as e:
    print("Error")
    logger.error(f"Interceptor error: {str(e)}")