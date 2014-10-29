require 'oauth'
require 'json'
require 'time'

class StreamingData

	def initialize
		@rawData = ""
		@parsedData = []
	end

	def append(buffer)
		@rawData += buffer
		parse
	end

	def parse
		#needs implementation depending on the data format
		@parsedData.push @rawData
		@rawData = ""
	end

	def all
		@parsedData
	end

	def clear
		@parsedData = []
	end

end

class StreamingJsonData < StreamingData

	#this method finds where the first complete JSON block ends
	def jsonBlockEnd
		openBrackets = 1
		cursor = @rawData.index("{")
		
		#if no { was found, then return
		if not cursor then return 0 end

		#loop until the number of open brackets is zero
		while openBrackets != 0

			#find the position of the next { and }
			posOpen = @rawData.index("{", cursor+1)
			posClose = @rawData.index("}", cursor+1)

			#if no more close brackets, then the block is not complete
			if posClose === nil
				return 0
			end

			#if the close is found first, then set one less open bracket
			if posOpen === nil or posClose < posOpen
				openBrackets -= 1
				cursor = posClose
			else
				openBrackets += 1
				cursor = posOpen
			end			
		end

		return cursor
	end

	#this method parses JSON data
	def parse
		loop do
			#find where the first block of data ends
			blockEnd = jsonBlockEnd

			#if we have no full blocks, then break
			if blockEnd == 0 then break end

			#parse the block of data and put it into the parsed data variable
			@parsedData.push JSON.parse @rawData[0 .. blockEnd]

			#now we remove the parsed data from the raw data
			@rawData = @rawData[blockEnd + 1 .. -1]
		end
	end

end

class Tweet

	attr_accessor :id, :text, :createdAt, :retweetId

	def initialize (jsonData)
		#we only store the parts that we need for this example
		@id = jsonData['id_str']
		@text = jsonData['text']

		if jsonData['created_at']
			@createdAt = Time.parse(jsonData['created_at'])
		else
			@createdAt = Time.now
		end

		if jsonData['retweeted_status']
			@retweetId = jsonData['retweeted_status']['id_str']
		else
			@retweetId = nil
		end
	end

end

class TopTweetCounter

	attr_accessor :tweets

	def initialize (duration)
		@tweets = {}
		@number = 10
		@duration = duration
	end

	#make sure the tweet data contains the needed info
	def checkTweet (jsonData)	
		if not jsonData['id_str'] then return false end
		if not jsonData['created_at'] then return false end
		if not jsonData['retweeted_status'] then return false end
		if not jsonData['retweeted_status']['id_str'] then return false end
		if not jsonData['retweeted_status']['text'] then return false end
		return true
	end

	#adds a single tweet from json
	def addTweet (jsonData)
		if checkTweet jsonData
			#save some memory
			jsonData.delete('text')
			jsonData['retweeted_status'].delete('created_at')

			#store both the retweet and the original tweet
			@tweets[jsonData['id_str']] = Tweet.new(jsonData)
			@tweets[jsonData['retweeted_status']['id_str']] = Tweet.new(jsonData['retweeted_status'])
		end
	end

	#adds an array of json tweets
	def addTweets (tweets)
		tweets.each do |jsonTweet|
			addTweet jsonTweet
		end
	end

	#returns an array of the top tweet ids by how many times they were retweeted 
	def getTopTweets
		#clean out old tweets that don't affect the count
		cleanOldTweets

		#start a new hash of top tweets
		retweetCount = Hash.new(0)
		
		#count all the retweets
		@tweets.each do |id, tweet|
			if tweet.retweetId and tweet.createdAt > Time.now - @duration * 60
				retweetCount[tweet.retweetId] += 1
			end
		end
		
		#sort and cut (our hash becomes an array)
		topTweets = retweetCount.sort_by do |key,value| value * -1 end
		topTweets = topTweets[0.. @number - 1]

		#returns [[id, retweets], ...]
		return topTweets
	end

	#removes all tweets older than the duration
	def cleanOldTweets	
		@tweets.each do |id, tweet|
			if tweet.createdAt < Time.now - @duration * 60
				@tweets.delete(id)
			end
		end
	end

end

class HTTPRequest

	def initialize (config)
		consumer_key = OAuth::Consumer.new(config[:consumer_key], config[:consumer_key_secret])
		access_token = OAuth::Token.new(config[:access_token], config[:access_token_secret])
		address = URI(config[:address])

		@http = Net::HTTP.new address.host, address.port
		@http.use_ssl = true
		@http.verify_mode = OpenSSL::SSL::VERIFY_PEER

		@request = Net::HTTP::Get.new address.request_uri
		@request.oauth! @http, consumer_key, access_token

		@http.start
	end

	def stream
		@http.request @request do |response|
			response.read_body do |chunk|
		        yield chunk
		    end
		end
	end

end

def tweetPrinter(topTweets, allTweets)

	#clear the screen
	puts "\e[H\e[2J"

	topTweets.each do |key, value|
		#clean the text so that it displays nicely on one line
		text = allTweets[key].text[0..40]
		text.delete! "\n"

		puts value.to_s + " : " + text
	end

end




#ask the user for the duration in minutes
duration = 0
while duration == 0
	puts "Over how many minutes would you like to see the top tweets?"
	duration = gets.chomp
	duration = duration.to_i
end

#connection to the twitter sample streaming api
twitterAPI = HTTPRequest.new ({
	consumer_key: "CONSUMER_KEY",
	consumer_key_secret: "CONSUMER_KEY_SECRET",
	access_token: "ACCESS_TOKEN",
	access_token_secret: "ACCESS_TOKEN_SECRET",
	address: "https://stream.twitter.com/1.1/statuses/sample.json"
})

#streamed data that will be processed in JSON format
streamedData = StreamingJsonData.new

#the tweet counter over the duration given
tweetCounter = TopTweetCounter.new duration

#the time of the last display refresh
lastDisplay = Time.now

#we read the data chunks from twitter as they come in
twitterAPI.stream do |chunk|

	#add the chunk that we pulled from twitter to our streaming data variable for processing
	#note that we need this intermediary step since chunks may not have a complete block of json
    streamedData.append chunk
    
    #add the tweets to our counter and clear the streamed data that we processed
	tweetCounter.addTweets streamedData.all
	streamedData.clear

    #print the top tweets
    if lastDisplay < Time.now - 1
    	lastDisplay = Time.now
    	tweetPrinter tweetCounter.getTopTweets, tweetCounter.tweets
    end
end
