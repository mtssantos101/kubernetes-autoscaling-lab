package com.kafka_worker.service;

import org.springframework.stereotype.Service;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import com.kafka_worker.messaging.MessageProducer;

@Service 
public class MessageService {
    private static final Logger logger = LoggerFactory.getLogger(MessageService.class);
    private final MessageProducer messageProducer;

    public MessageService(MessageProducer messageProducer) {
        this.messageProducer = messageProducer;
    }

    public void processMessage(String messageId) {
        logger.info("Processando mensagem: {}", messageId);
        messageProducer.publish(messageId);
    }
}
