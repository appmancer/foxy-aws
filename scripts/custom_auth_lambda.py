import json

def lambda_handler(event, context):
    if event['triggerSource'] == "DefineAuthChallenge_Authentication":
        event['response']['challengeName'] = 'CUSTOM_CHALLENGE'
        event['response']['issueTokens'] = True
        event['response']['failAuthentication'] = False
    elif event['triggerSource'] == "CreateAuthChallenge":
        event['response']['publicChallengeParameters'] = {}
        event['response']['privateChallengeParameters'] = {}
        event['response']['challengeMetadata'] = 'CUSTOM_CHALLENGE'
    elif event['triggerSource'] == "VerifyAuthChallengeResponse":
        event['response']['answerCorrect'] = True
    
    return event

