# Description:
#   NodeJS Proxy for deploying OpsWorks projects using Spark events
#
# Dependencies:
#   aws-sdk
#   underscore
#   xtend
#
# Configuration:
#   AWS_ACCESS_KEY_ID: Amazon Web Services access key
#   AWS_SECRET_ACCESS_KEY: Amazon Web Services secret token
#   SPARK_DEVICE_ID: Spark Device ID
#   SPARK_ACCESS_TOKEN: Spark Access Token
#   OPSWORKS_APP_ID: OpsWorks App ID
#   OPSWORKS_STACK_ID: OpsWorks Stack ID
#
# Author:
#   donaldpiret

extend = require 'xtend'
request = require 'request'
https = require 'https'
AWS = require 'aws-sdk'
_ = require 'underscore'

deviceId = process.env.SPARK_DEVICE_ID
accessToken = process.env.SPARK_ACCESS_TOKEN

aws_key = process.env.AWS_ACCESS_KEY_ID
aws_secret = process.env.AWS_SECRET_ACCESS_KEY
AWS.config.update(accessKeyId: aws_key, secretAccessKey: aws_secret, region: 'us-east-1')

appId = process.env.OPSWORKS_APP_ID
appStack = process.env.OPSWORKS_STACK_ID

withMigrations = true
deployMessage = "Deployment from Spark Button"
statusMessage = "Waiting"

requestObj = request(
  uri: "https://api.spark.io/v1/devices/#{deviceId}/events?access_token=#{accessToken}"
  method: "GET"
)

chunks = []

class OpsWorksClient
  constructor: (@https, @aws) ->
    this.client = new @aws.OpsWorks()
    @stacks_cache = []
    @apps_cache = {}
    @all_apps_cache = []

  getStacks: (params, cb) ->
    if @stacks_cache.length
      cb(null, @stacks_cache)
    else
      request = this.client.describeStacks params, (err, data) ->
        @stacks_cache = data unless err
        cb(err, @stacks_cache)

  getApps: (params, cb) ->
    that = @
    if @apps_cache[params["StackId"]] and @apps_cache[params["StackId"]].length
      cb(null, @apps_cache[params["StackId"]])
    else
      this.client.describeApps params, (err, data) ->
        that.apps_cache[params["StackId"]] = data unless err
        cb(err, that.apps_cache[params["StackId"]])

  getAllApps: (cb) ->
    that = @
    if @all_apps_cache.length
      cb(null, @all_apps_cache)
    else
      this.getStacks {}, (err, data) ->
        unless err
          remainingStacks = data["Stacks"].length
          for stack in data["Stacks"]
            that.getApps {StackId: stack["StackId"]}, (err, data) ->
              remainingStacks--
              unless err
                for app in data["Apps"]
                  that.all_apps_cache.push(app)
                if remainingStacks == 0
                  cb(null, that.all_apps_cache)
              else
                console.log("Could not get apps from stack: #{JSON.stringify(err)}")
                cb(err, that.all_apps_cache)
        else
          console.log("Could not get stacks: #{JSON.stringify(err)}")
          cb(err, that.all_apps_cache)


  deploy: (appId, appStack, withMigrations, msg, cb, finishedCb) ->
    that = this
    this.getInstanceIds appStack, (instanceIds) ->
      console.log "StackId: #{appStack}, AppId: #{appId}, InstanceIds: #{instanceIds}, Comment: #{msg}, Command: Args: Migrate: #{withMigrations}"
      request = that.client.createDeployment {StackId: appStack, AppId: appId, InstanceIds: instanceIds, Comment: msg, Command: {Name: 'deploy', Args: {'migrate': ["#{withMigrations}"]}}}, (err, data) ->
        that.registerRunningDeploy(appId, appStack, data, finishedCb) unless err
        cb(err, data);

  getInstanceIds: (appStack, cb) ->
    that = this
    request = this.client.describeInstances {StackId: appStack}, (err, data) ->
      unless err
        console.log "Got instance id's #{data["Instances"]}"
        cb (instance["InstanceId"] for instance in data["Instances"])
      else
        console.log "Err #{err}, could not get instance id's"

  registerRunningDeploy: (appId, appStack, deploy, cb) ->
    console.log "Registering running deploy: #{deploy}"
    that = this
    intervalId = setInterval () ->
      that.client.describeDeployments {DeploymentIds: [deploy["DeploymentId"]]}, (err, data) ->
        unless err
          console.log "Got deployment data: #{data}"
          deploy = data["Deployments"][0]
          console.log "Deploy status: #{deploy["Status"]}"
          if deploy["Status"] isnt 'running'
            console.log "Deploy isn't running anymore, sending callback"
            clearInterval intervalId
            cb deploy
        else
          console.log "Err #{err}, clearing intervalid"
          clearInterval intervalId
    , 10000

client = new OpsWorksClient https, AWS

appendToQueue = (arr) ->
  i = 0

  while i < arr.length
    line = (arr[i] or "").trim()
    if line is ""
      i++
      continue
    chunks.push line
    if line.indexOf("data:") is 0
      processItem chunks
      chunks = []
    i++
  return

processItem = (arr) ->
  obj = {}
  i = 0

  while i < arr.length
    line = arr[i]
    if line.indexOf("event:") is 0
      obj.name = line.replace("event:", "").trim()
    else if line.indexOf("data:") is 0
      line = line.replace("data:", "")
      obj = extend(obj, JSON.parse(line))
    i++
  console.log JSON.stringify(obj)
  if obj.name == 'opsworks-deploy'
    processDeploy(obj)
  return
  
processDeploy = (obj) ->
  statusMessage = "Deploying..."
  data = JSON.parse(obj.data)
  if data and data.action == 'deploy'
    client.deploy appId, appStack, withMigrations, deployMessage, (err, data) ->
      if err
        console.log "Error deploying: #{JSON.stringify(err)}"
      else
        console.log "Deploying App"
    , (finished) ->
      statusMessage = "Waiting"
      console.log "Deploy finished, status: #{finished["Status"]}"

onData = (event) ->
  chunk = event.toString()
  appendToQueue chunk.split("\n")
  return

requestObj.on "data", onData
