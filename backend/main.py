#!/usr/bin/env python3
"""
AstraMesh QVic Reforge Chalice - Main FastAPI Application
AI-powered knowledge aggregator with self-healing capabilities
"""

import asyncio
import logging
import os
from datetime import datetime
from typing import List, Optional, Dict, Any
from contextlib import asynccontextmanager

import httpx
import tweepy
from fastapi import FastAPI, HTTPException, BackgroundTasks
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field
from dotenv import load_dotenv

# LangChain imports
from langchain.text_splitter import RecursiveCharacterTextSplitter
from langchain_openai import ChatOpenAI
from langchain.schema import HumanMessage

# Load environment variables
load_dotenv()

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Global variables for services
twitter_client = None
openai_client = None
aggregation_tasks = []

class AggregationRequest(BaseModel):
    """Request model for content aggregation"""
    query: str = Field(..., description="Search query for content aggregation")
    sources: List[str] = Field(default=["web", "twitter"], description="Sources to aggregate from")
    max_results: int = Field(default=10, description="Maximum number of results per source")
    summarize: bool = Field(default=True, description="Whether to generate AI summary")

class ContentItem(BaseModel):
    """Model for individual content items"""
    title: str
    content: str
    source: str
    url: Optional[str] = None
    timestamp: datetime
    metadata: Dict[str, Any] = Field(default_factory=dict)

class AggregationResult(BaseModel):
    """Model for aggregation results"""
    query: str
    items: List[ContentItem]
    summary: Optional[str] = None
    total_items: int
    sources_used: List[str]
    processing_time: float

class HealthStatus(BaseModel):
    """Health check response model"""
    status: str
    timestamp: datetime
    services: Dict[str, str]
    version: str = "1.0.0"

async def initialize_services():
    """Initialize external services"""
    global twitter_client, openai_client
    
    try:
        # Initialize Twitter client
        twitter_bearer_token = os.getenv("TWITTER_BEARER_TOKEN")
        if twitter_bearer_token:
            twitter_client = tweepy.Client(bearer_token=twitter_bearer_token)
            logger.info("Twitter client initialized successfully")
        else:
            logger.warning("Twitter Bearer Token not found - Twitter aggregation disabled")
        
        # Initialize OpenAI client
        openai_api_key = os.getenv("OPENAI_API_KEY")
        if openai_api_key:
            openai_client = ChatOpenAI(
                api_key=openai_api_key,
                model="gpt-3.5-turbo",
                temperature=0.3
            )
            logger.info("OpenAI client initialized successfully")
        else:
            logger.warning("OpenAI API Key not found - AI summarization disabled")
            
    except Exception as e:
        logger.error(f"Error initializing services: {e}")

@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan manager"""
    # Startup
    logger.info("Starting AstraMesh QVic Reforge Chalice...")
    await initialize_services()
    yield
    # Shutdown
    logger.info("Shutting down AstraMesh QVic Reforge Chalice...")

# Initialize FastAPI app
app = FastAPI(
    title="AstraMesh QVic Reforge Chalice",
    description="AI-powered knowledge aggregator with self-healing capabilities",
    version="1.0.0",
    lifespan=lifespan
)

# Add CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

async def aggregate_web_content(query: str, max_results: int = 10) -> List[ContentItem]:
    """Aggregate content from web sources"""
    items = []
    
    try:
        # Use DuckDuckGo search API (no API key required)
        async with httpx.AsyncClient() as client:
            search_url = f"https://api.duckduckgo.com/?q={query}&format=json&no_html=1&skip_disambig=1"
            response = await client.get(search_url, timeout=10.0)
            
            if response.status_code == 200:
                data = response.json()
                
                # Process related topics
                for topic in data.get("RelatedTopics", [])[:max_results]:
                    if isinstance(topic, dict) and "Text" in topic:
                        items.append(ContentItem(
                            title=topic.get("FirstURL", "").split("/")[-1].replace("-", " ").title(),
                            content=topic["Text"],
                            source="web",
                            url=topic.get("FirstURL"),
                            timestamp=datetime.now(),
                            metadata={"search_engine": "duckduckgo"}
                        ))
                
                # Process abstract if available
                if data.get("Abstract"):
                    items.append(ContentItem(
                        title=data.get("Heading", query.title()),
                        content=data["Abstract"],
                        source="web",
                        url=data.get("AbstractURL"),
                        timestamp=datetime.now(),
                        metadata={"type": "abstract", "search_engine": "duckduckgo"}
                    ))
                    
    except Exception as e:
        logger.error(f"Error aggregating web content: {e}")
    
    return items

async def aggregate_twitter_content(query: str, max_results: int = 10) -> List[ContentItem]:
    """Aggregate content from Twitter"""
    items = []
    
    if not twitter_client:
        logger.warning("Twitter client not available")
        return items
    
    try:
        # Search for tweets
        tweets = twitter_client.search_recent_tweets(
            query=query,
            max_results=min(max_results, 100),  # Twitter API limit
            tweet_fields=["created_at", "author_id", "public_metrics"]
        )
        
        if tweets.data:
            for tweet in tweets.data:
                items.append(ContentItem(
                    title=f"Tweet by {tweet.author_id}",
                    content=tweet.text,
                    source="twitter",
                    url=f"https://twitter.com/i/status/{tweet.id}",
                    timestamp=tweet.created_at or datetime.now(),
                    metadata={
                        "tweet_id": tweet.id,
                        "author_id": tweet.author_id,
                        "metrics": tweet.public_metrics
                    }
                ))
                
    except Exception as e:
        logger.error(f"Error aggregating Twitter content: {e}")
    
    return items

async def generate_summary(items: List[ContentItem], query: str) -> Optional[str]:
    """Generate AI summary of aggregated content"""
    if not openai_client or not items:
        return None
    
    try:
        # Combine content for summarization
        combined_content = "\n\n".join([
            f"Source: {item.source}\nTitle: {item.title}\nContent: {item.content}"
            for item in items[:10]  # Limit to first 10 items to avoid token limits
        ])
        
        # Create prompt for summarization
        prompt = f"""
        Please provide a comprehensive summary of the following content related to the query: "{query}"
        
        Content:
        {combined_content}
        
        Summary should be:
        - Concise but informative (2-3 paragraphs)
        - Highlight key insights and trends
        - Mention different perspectives if present
        - Be objective and factual
        """
        
        # Generate summary using LangChain
        message = HumanMessage(content=prompt)
        response = await openai_client.ainvoke([message])
        
        return response.content
        
    except Exception as e:
        logger.error(f"Error generating summary: {e}")
        return None

@app.get("/", response_class=HTMLResponse)
async def root():
    """Serve the main frontend page"""
    try:
        with open("../frontend/index.html", "r") as f:
            return HTMLResponse(content=f.read())
    except FileNotFoundError:
        return HTMLResponse(content="""
        <html>
            <head><title>AstraMesh QVic Reforge Chalice</title></head>
            <body>
                <h1>🚀 AstraMesh QVic Reforge Chalice</h1>
                <p>AI-powered knowledge aggregator is running!</p>
                <p>API Documentation: <a href="/docs">/docs</a></p>
            </body>
        </html>
        """)

@app.get("/health", response_model=HealthStatus)
async def health_check():
    """Health check endpoint for monitoring"""
    services = {
        "twitter": "available" if twitter_client else "unavailable",
        "openai": "available" if openai_client else "unavailable",
        "web_aggregation": "available"
    }
    
    return HealthStatus(
        status="healthy",
        timestamp=datetime.now(),
        services=services
    )

@app.post("/aggregate", response_model=AggregationResult)
async def aggregate_content(request: AggregationRequest, background_tasks: BackgroundTasks):
    """Main endpoint for content aggregation"""
    start_time = datetime.now()
    all_items = []
    sources_used = []
    
    try:
        # Aggregate from requested sources
        tasks = []
        
        if "web" in request.sources:
            tasks.append(aggregate_web_content(request.query, request.max_results))
            sources_used.append("web")
        
        if "twitter" in request.sources and twitter_client:
            tasks.append(aggregate_twitter_content(request.query, request.max_results))
            sources_used.append("twitter")
        
        # Execute aggregation tasks concurrently
        if tasks:
            results = await asyncio.gather(*tasks, return_exceptions=True)
            
            for result in results:
                if isinstance(result, list):
                    all_items.extend(result)
                elif isinstance(result, Exception):
                    logger.error(f"Aggregation task failed: {result}")
        
        # Sort items by timestamp (newest first)
        all_items.sort(key=lambda x: x.timestamp, reverse=True)
        
        # Generate summary if requested
        summary = None
        if request.summarize and all_items:
            summary = await generate_summary(all_items, request.query)
        
        processing_time = (datetime.now() - start_time).total_seconds()
        
        return AggregationResult(
            query=request.query,
            items=all_items,
            summary=summary,
            total_items=len(all_items),
            sources_used=sources_used,
            processing_time=processing_time
        )
        
    except Exception as e:
        logger.error(f"Error in content aggregation: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/status")
async def get_status():
    """Get current system status"""
    return {
        "service": "AstraMesh QVic Reforge Chalice",
        "status": "running",
        "timestamp": datetime.now().isoformat(),
        "active_tasks": len(aggregation_tasks),
        "services": {
            "twitter": twitter_client is not None,
            "openai": openai_client is not None
        }
    }

if __name__ == "__main__":
    import uvicorn
    
    port = int(os.getenv("PORT", 8000))
    host = os.getenv("HOST", "0.0.0.0")
    
    uvicorn.run(
        "main:app",
        host=host,
        port=port,
        reload=True,
        log_level="info"
    )