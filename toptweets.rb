require 'oauth'
require 'json'
require 'time'

class StreamingJsonData
	attr_accessor :data, :parsedData

	def initialize
		@data = ""
		@parsedData = []
	end

	def jsonBlockEnd
		#this method finds where the JSON block ends
		open = 1
		cursor = @data.index("{")
		if not cursor then return 0 end

			while open != 0

				posOpen = @data.index("{", cursor+1)
				posClose = @data.index("}", cursor+1)

				if posClose === nil
					return 0
				end

				if posOpen === nil
					open -= 1
					cursor = posClose
				else
					if posOpen < posClose
						open += 1
						cursor = posOpen
					else
						open -= 1
						cursor = posClose
					end			
				end
			end

		return cursor
	end

	def parse
		loop do
			blockEnd = jsonBlockEnd

			if blockEnd == 0 then break end

			#once we know the end of the first block of json, we place that into our parsed data array
			@parsedData.push JSON.parse @data[0 .. blockEnd]

			#now we remove the parsed data from the old data
			@data = @data[blockEnd + 1 .. -1]
		end
	end

	def append(buffer)
		#append and automatically parse the data
		@data += buffer
		parse
	end

end

class Tweet
	#we only store the parts that we want to keep
	attr_accessor :id, :text, :createdAt, :retweetId

	def initialize (jsonTweet)
		@id = jsonTweet['id_str']
		@text = jsonTweet['text']

		if jsonTweet['created_at']
			@createdAt = Time.parse(jsonTweet['created_at'])
		else
			#this will allow cleaning up the retweeted tweets
			#since their creation date would otherwise be long ago
			@createdAt = Time.now
		end

		if jsonTweet['retweeted_status']
			@retweetId = jsonTweet['retweeted_status']['id_str']
		else
			@retweetId = nil
		end
	end
end

class TopTweetCounter
	attr_accessor :number, :duration, :tweets
	def initialize (duration)
		@tweets = {}
		@number = 10
		@duration = duration
	end

	def checkTweet (jsonTweet)
		#make sure the tweet data is what we expect
		if not jsonTweet['id_str'] then return false end
		if not jsonTweet['created_at'] then return false end
		if not jsonTweet['retweeted_status'] then return false end
		if not jsonTweet['retweeted_status']['id_str'] then return false end
		if not jsonTweet['retweeted_status']['text'] then return false end
		return true
	end

	def addTweet (jsonTweet)
		if checkTweet jsonTweet
			
			#save some memory
			jsonTweet.delete('text')
			jsonTweet['retweeted_status'].delete('created_at')

			#store both the retweet and the original tweet
			@tweets[jsonTweet['id_str']] = Tweet.new(jsonTweet)
			@tweets[jsonTweet['retweeted_status']['id_str']] = Tweet.new(jsonTweet['retweeted_status'])

		end
	end

	def getTopTweets
		retweetCount = Hash.new(0)
		
		#count all the retweets
		@tweets.each do |id, tweet|
			if tweet.retweetId and tweet.createdAt > Time.now - @duration * 60
				retweetCount[tweet.retweetId] += 1
			end
		end
		
		#sort and cut
		topTweets = retweetCount.sort_by do |key,value| value * -1 end
		topTweets = topTweets[0.. @number - 1]

		return topTweets
	end
	def printTopTweets
		topTweets = getTopTweets

		#clear the screen
		puts "\e[H\e[2J"
		topTweets.each do |key, value|
			
			#clean the text so that it displays nicely
			text = @tweets[key].text[0..40]
			text.delete! "\n"

			puts value.to_s + " : " + text
		end

		#clean out old tweets that don't affect the count
		cleanOldTweets
	end
	def cleanOldTweets
		#removes all tweets older than the rolling time
		@tweets.each do |id, tweet|
			if tweet.createdAt < Time.now - @duration * 60
				@tweets.delete(id)
			end
		end
	end
end

class HTTPRequest
	def initialize (consumer_key, access_token, address)
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



#ask the user for the number of minutes
duration = 0
while duration == 0
	puts "Over how many minutes would you like to see the top tweets?"
	duration = gets.chomp
	duration = duration.to_i
end


#this is the twitter specific data for the streaming API
consumer_key = OAuth::Consumer.new(
    "CONSUMER_KEY",
    "CONSUMER_KEY_SECRET")
access_token = OAuth::Token.new(
    "ACCESS_TOKEN",
    "ACCESS_TOKEN_SECRET")

address = URI("https://stream.twitter.com/1.1/statuses/sample.json")


twitterAPI = HTTPRequest.new consumer_key, access_token, address
bufferData = StreamingJsonData.new
tweetCounter = TopTweetCounter.new duration

#we read the data chunks from twitter as they come in
twitterAPI.stream do |chunk|

	#add the chunk that we pulled from twitter to the data buffer
    bufferData.append chunk
    
    #add all the parsed data from the buffer to the tweet counter
    bufferData.parsedData.each do |tweet|
    	tweetCounter.addTweet tweet
    end

    #clear the buffer
    bufferData.parsedData = []

    #print the top tweets
    tweetCounter.printTopTweets
end
