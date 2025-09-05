#!/usr/bin/env python3
"""
Basic tests for AstraMesh QVic Reforge Chalice
"""

import pytest
import asyncio
from datetime import datetime
from fastapi.testclient import TestClient
from unittest.mock import Mock, patch

# Import the main app
import sys
import os
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from main import app, ContentItem, AggregationRequest

client = TestClient(app)

class TestBasicEndpoints:
    """Test basic API endpoints"""
    
    def test_root_endpoint(self):
        """Test the root endpoint returns HTML"""
        response = client.get("/")
        assert response.status_code == 200
        assert "text/html" in response.headers["content-type"]
    
    def test_health_endpoint(self):
        """Test health check endpoint"""
        response = client.get("/health")
        assert response.status_code == 200
        
        data = response.json()
        assert data["status"] == "healthy"
        assert "timestamp" in data
        assert "services" in data
        assert "version" in data
    
    def test_status_endpoint(self):
        """Test status endpoint"""
        response = client.get("/status")
        assert response.status_code == 200
        
        data = response.json()
        assert data["service"] == "AstraMesh QVic Reforge Chalice"
        assert data["status"] == "running"
        assert "timestamp" in data

class TestModels:
    """Test Pydantic models"""
    
    def test_content_item_model(self):
        """Test ContentItem model validation"""
        item = ContentItem(
            title="Test Title",
            content="Test content",
            source="web",
            url="https://example.com",
            timestamp=datetime.now()
        )
        
        assert item.title == "Test Title"
        assert item.source == "web"
        assert item.url == "https://example.com"
    
    def test_aggregation_request_model(self):
        """Test AggregationRequest model validation"""
        request = AggregationRequest(
            query="test query",
            sources=["web", "twitter"],
            max_results=5,
            summarize=True
        )
        
        assert request.query == "test query"
        assert request.sources == ["web", "twitter"]
        assert request.max_results == 5
        assert request.summarize is True
    
    def test_aggregation_request_defaults(self):
        """Test AggregationRequest default values"""
        request = AggregationRequest(query="test")
        
        assert request.sources == ["web", "twitter"]
        assert request.max_results == 10
        assert request.summarize is True

class TestAggregation:
    """Test content aggregation functionality"""
    
    @patch('main.httpx.AsyncClient')
    def test_aggregate_endpoint_web_only(self, mock_client):
        """Test aggregation endpoint with web source only"""
        # Mock the HTTP response
        mock_response = Mock()
        mock_response.status_code = 200
        mock_response.json.return_value = {
            "RelatedTopics": [
                {
                    "Text": "Test content from web",
                    "FirstURL": "https://example.com/test"
                }
            ],
            "Abstract": "Test abstract",
            "Heading": "Test Heading",
            "AbstractURL": "https://example.com/abstract"
        }
        
        mock_client.return_value.__aenter__.return_value.get.return_value = mock_response
        
        response = client.post("/aggregate", json={
            "query": "test query",
            "sources": ["web"],
            "max_results": 5,
            "summarize": False
        })
        
        assert response.status_code == 200
        data = response.json()
        
        assert data["query"] == "test query"
        assert data["total_items"] >= 0
        assert "web" in data["sources_used"]
        assert "processing_time" in data
    
    def test_aggregate_endpoint_invalid_request(self):
        """Test aggregation endpoint with invalid request"""
        response = client.post("/aggregate", json={
            "sources": ["web"],  # Missing required 'query' field
            "max_results": 5
        })
        
        assert response.status_code == 422  # Validation error

@pytest.mark.asyncio
class TestAsyncFunctions:
    """Test async functions"""
    
    async def test_content_item_creation(self):
        """Test creating ContentItem instances"""
        item = ContentItem(
            title="Async Test",
            content="Async content",
            source="test",
            timestamp=datetime.now()
        )
        
        assert item.title == "Async Test"
        assert item.source == "test"

if __name__ == "__main__":
    pytest.main([__file__, "-v"])