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

class TopTweetCounter

	attr_accessor :tweets, :retweets

	def initialize (duration)
		@tweets = {}		# {id: [count, text], id: [count, text], ..}
		@retweets = []		# [ [id, time], [id, time], ...]
		
		@topList = []		# [ id, id, ...]
		@listLength = 10
		@minOfTop = 0

		@duration = duration
	end

	def getTopList
		cleanOldTweets
		@topList.sort! {|a,b| @tweets[b][0] <=> @tweets[a][0]}
	end

	#see if the tweet should be added to our top 10 list
	def addToList(id)
		if (@tweets[id][0] == @minOfTop + 1 and @topList.find_index(id) == nil)

			#add it to the list
			@topList.push id

			#find the smallest element
			smallest = @topList.min_by {|a| @tweets[a][0]}

			#find the new lowest element
			if @topList.length < @listLength 
				@minOfTop = 0
			elsif @topList.length > @listLength 
				#@topList = @topList[0 .. @listLength-1]
				@topList.slice! (@topList.find_index smallest)
				smallest = @topList.min_by {|a| @tweets[a][0]}
				@minOfTop = @tweets[smallest][0]
			else
				puts smallest
				@minOfTop = @tweets[smallest][0]
			end
		end
	end

	#see if the tweet should be removed from our top 10 list
	def removeFromList(id)
		if ( @tweets[id] and @tweets[id][0] == @minOfTop - 1 and @topList.find_index(id) )

			#remove this element
			@topList.slice! @topList.find_index(id)

			#find the largest element not yet on the list
			largest = 0
			largestId = nil
			@tweets.each do |key, value|
				if ( value[0] > largest ) and ( @topList.find { |a| a == key} == nil )
					largest = value[0]
					largestId = key
				end
			end

			#add the largest to the list
			@topList.push largestId

			#find the new lowest element
			smallest = @topList.min_by {|a| @tweets[a][0]}
			@minOfTop = @tweets[smallest][0]
		end
	end	

	#adds a single tweet from json
	def addTweet (jsonData)
		if jsonData['retweeted_status']

			#is the current original tweet in our list?
			if @tweets[jsonData['retweeted_status']['id_str']]
				@tweets[jsonData['retweeted_status']['id_str']][0] += 1
			else
				@tweets[jsonData['retweeted_status']['id_str']] = [1, jsonData['retweeted_status']['text']]
			end

			#add the retweet to our list
			@retweets.push [jsonData['retweeted_status']['id_str'], Time.parse(jsonData['created_at'])]
			
			# check if the current tweet should be in the top list
			addToList jsonData['retweeted_status']['id_str']
		end
	end

	#adds an array of json tweets
	def addTweets (tweets)
		tweets.each do |jsonTweet|
			addTweet jsonTweet
		end
	end

	#removes all tweets older than the duration
	def cleanOldTweets	
		loop do
			if @retweets == [] then break end

			#check the closest retweet to expiring, if it didn't expire, no need to check other retweets
			if @retweets[0][1] < Time.now - @duration * 60

				#lower the count for the original tweet
				@tweets[@retweets[0][0]][0] -= 1

				# check if the expired retweet would push the tweet out of the top list
				removeFromList @retweets.shift		

				#if the original tweet falls to zero retweets, then delete it
				if @tweets[@retweets[0][0]][0] == 0 then @tweets.delete(@retweets[0][0]) end

			else
				break
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

def tweetPrinter(topTweets, tweets)
	#clear the screen
	puts "\e[H\e[2J"

	#tweets is [ [id, [retweets, text]], ...]
	topTweets.each do |value|
		#clean the text so that it displays nicely on one line
		text = tweets[value][1][0..40]
		text.delete! "\n"
		puts tweets[value][0].to_s + " : " + text
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
		
		tweetPrinter tweetCounter.getTopList, tweetCounter.tweets
	end
end