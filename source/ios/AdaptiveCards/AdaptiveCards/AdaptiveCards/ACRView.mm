//
//  ACRView.m
//  ACRView
//
//  Copyright © 2018 Microsoft. All rights reserved.
//

#import "ACRView.h"
#import "ACOHostConfigPrivate.h"
#import "ACOAdaptiveCardPrivate.h"
#import "SharedAdaptiveCard.h"
#import "ACRRendererPrivate.h"
#import "ACRRegistration.h"
#import <AVFoundation/AVFoundation.h>
#import "Container.h"
#import "ColumnSet.h"
#import "Column.h"
#import "Image.h"
#import "ACRImageRenderer.h"
#import "TextBlock.h"
#import "ACRTextBlockRenderer.h"
#import "MarkDownParser.h"
#import "ImageSet.h"
#import "ACRUILabel.h"
#import "ACRUIImageView.h"
#import "FactSet.h"

using namespace AdaptiveCards;

@implementation ACRView
{
    ACOAdaptiveCard *_adaptiveCard;
    ACOHostConfig *_hostConfig;
    NSMutableDictionary *_imageViewMap;
    NSMutableDictionary *_textMap;
    NSMutableDictionary *_actionsMap;
    dispatch_queue_t _serial_queue;
    dispatch_queue_t _serial_text_queue;
    dispatch_queue_t _global_queue;
    dispatch_group_t _async_tasks_group;
    int _serialNumber;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if(self){
        std::shared_ptr<HostConfig> cHostConfig = std::make_shared<HostConfig>();
        _hostConfig = [[ACOHostConfig alloc] initWithConfig:cHostConfig];
        _imageViewMap = [[NSMutableDictionary alloc] init];
        _textMap = [[NSMutableDictionary alloc] init];
        _actionsMap = [[NSMutableDictionary alloc] init];
        _serial_queue = dispatch_queue_create("io.adaptiveCards.serial_queue", DISPATCH_QUEUE_SERIAL);
        _serial_text_queue = dispatch_queue_create("io.adaptiveCards.serial_text_queue", DISPATCH_QUEUE_SERIAL);
        _global_queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
        _async_tasks_group = dispatch_group_create();
        _serialNumber = 0;
    }
    return self;
}

// Initializes ACRView instance with HostConfig and AdaptiveCard
- (instancetype)init:(ACOAdaptiveCard *)card
          hostconfig:(ACOHostConfig *)config
     widthConstraint:(float)width
{
    self = [self initWithFrame:CGRectMake(0, 0, width, 0)];
    if(self){
        _adaptiveCard = card;
        if(config){
            _hostConfig = config;
        }
        [self render];
    }
    return self;
}

- (UIView *)render
{
    NSMutableArray *inputs = [[NSMutableArray alloc] init];

    UIView *newView = [ACRRenderer renderWithAdaptiveCards:[_adaptiveCard card] inputs:inputs context:self containingView:self hostconfig:_hostConfig];

    if(self.frame.size.width){
        [NSLayoutConstraint constraintWithItem:newView attribute:NSLayoutAttributeWidth relatedBy:NSLayoutRelationEqual toItem:nil attribute:NSLayoutAttributeNotAnAttribute multiplier:1.0 constant:self.frame.size.width].active = YES;
    }
    ContainerStyle style = ([_hostConfig getHostConfig]->adaptiveCard.allowCustomStyle)? [_adaptiveCard card]->GetStyle(): ContainerStyle::Default;
    if(style != ContainerStyle::None)
    {
        unsigned long num = 0;
        if(style == ContainerStyle::Emphasis)
        {
            num = std::stoul([_hostConfig getHostConfig]->containerStyles.emphasisPalette.backgroundColor.substr(1), nullptr, 16);
        }
        else
        {
            num = std::stoul([_hostConfig getHostConfig]->containerStyles.defaultPalette.backgroundColor.substr(1), nullptr, 16);
        }
        newView.backgroundColor =
        [UIColor colorWithRed:((num & 0x00FF0000) >> 16) / 255.0
                        green:((num & 0x0000FF00) >>  8) / 255.0
                         blue:((num & 0x000000FF)) / 255.0
                        alpha:((num & 0xFF000000) >> 24) / 255.0];
    }
    std::string backgroundImage = [_adaptiveCard card]->GetBackgroundImage();
    NSString* imgUrl = nil;
    if(!backgroundImage.empty()){
        imgUrl = [[NSString alloc] initWithCString:backgroundImage.c_str() encoding:NSUTF8StringEncoding];
    }
    if (imgUrl){
        NSURL *url = [NSURL URLWithString:imgUrl];
        UIImage *img = [UIImage imageWithData:[NSData dataWithContentsOfURL:url]];
        if(img){
            ACRUIImageView *imgView = [[ACRUIImageView alloc] initWithImage:img];
            [newView addSubview:imgView];
            [newView sendSubviewToBack:imgView];
            [newView setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
            [newView setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisVertical];
            NSArray<NSString *> *visualFormats = [NSArray arrayWithObjects:@"H:|[imgView]", @"V:|[imgView]", nil];
            NSDictionary *viewMap = NSDictionaryOfVariableBindings(imgView);
            for(NSString *constraint in visualFormats){
                [NSLayoutConstraint activateConstraints:[NSLayoutConstraint constraintsWithVisualFormat:constraint options:0 metrics:nil views:viewMap]];
            }
        }
    }
    [self callDidLoadElementsIfNeeded];
    return newView;
}

- (void)waitForAsyncTasksToFinish
{
    dispatch_group_wait(_async_tasks_group, DISPATCH_TIME_FOREVER);
    [self callDidLoadElementsIfNeeded];
}

- (void)callDidLoadElementsIfNeeded
{
    // Call back app with didLoadElements
    if ([[self acrActionDelegate] respondsToSelector:@selector(didLoadElements)])
    {
        [[self acrActionDelegate] didLoadElements];
    }
}

// Walk through adaptive cards elements recursively and if images/images set/TextBlocks are found process them concurrently
- (void)addTasksToConcurrentQueue:(std::vector<std::shared_ptr<BaseCardElement>> const &)body
{
    ACRRegistration *rendererRegistration = [ACRRegistration getInstance];

    for(auto &elem : body)
    {
        if([rendererRegistration isElementRendererOverriden:(ACRCardElementType) elem->GetElementType()] == YES){
            continue;
        }
        switch (elem->GetElementType())
        {
            case CardElementType::TextBlock:
            {
                std::shared_ptr<TextBlock> textBlockElement = std::static_pointer_cast<TextBlock>(elem);
                TextConfig textConfig =
                {
                    .weight = textBlockElement->GetTextWeight(),
                    .size = textBlockElement->GetTextSize(),
                    .color = textBlockElement->GetTextColor(),
                    .isSubtle = textBlockElement->GetIsSubtle(),
                    .wrap = textBlockElement->GetWrap()
                };

                /// tag a base card element with unique key
                NSString *key = [NSString stringWithCString:textBlockElement->GetId().c_str() encoding:[NSString defaultCStringEncoding]];
                std::string text;
                [self processTextConcurrently:textBlockElement
                                  elementType:CardElementType::TextBlock
                                   textConfig:textConfig
                                    elementId:key
                                         text:text];
                break;
            }
            case CardElementType::FactSet:
            {
                [self tagBaseCardElement:elem];
                std::shared_ptr<FactSet> factSet = std::dynamic_pointer_cast<FactSet>(elem);
                NSString *key = [NSString stringWithCString:elem->GetId().c_str() encoding:[NSString defaultCStringEncoding]];
                key = [key stringByAppendingString:@"*"];
                int rowFactId = 0;
                for(auto fact : factSet->GetFacts()) {
                    std::string title = fact->GetTitle();
                    [self processTextConcurrently:elem
                                      elementType:CardElementType::FactSet
                                       textConfig:[_hostConfig getHostConfig]->factSet.title
                                        elementId:[key stringByAppendingString:[[NSNumber numberWithInt:rowFactId++] stringValue]]
                                             text:title];

                    std::string value = fact->GetValue();
                    [self processTextConcurrently:elem
                                      elementType:CardElementType::FactSet
                                       textConfig:[_hostConfig getHostConfig]->factSet.value
                                        elementId:[key stringByAppendingString:[[NSNumber numberWithInt:rowFactId++] stringValue]]
                                             text:fact->GetValue()];
                }
                break;
            }
            case CardElementType::Image:
            {
                /// tag a base card element with unique key
                std::shared_ptr<Image>imgElem = std::static_pointer_cast<Image>(elem);
                // dispatch to concurrent queue
                [self processImageConcurrently:imgElem];
                break;
            }
            case CardElementType::ImageSet:
            {
                std::shared_ptr<ImageSet>imgSetElem = std::static_pointer_cast<ImageSet>(elem);
                for(auto img :imgSetElem->GetImages()) { // loops through images in image set
                    std::shared_ptr<BaseCardElement> baseImgElem = std::static_pointer_cast<BaseCardElement>(img);
                    img->SetImageSize(imgSetElem->GetImageSize());

                    if([rendererRegistration isElementRendererOverriden:(ACRCardElementType) CardElementType::Image] == NO){
                        /// tag a base card element with unique key
                        [self processImageConcurrently:img];
                    }
                }
                break;
            }
            // continue on search
            case CardElementType::Container:
            {
                std::shared_ptr<Container> container = std::static_pointer_cast<Container>(elem);
                std::vector<std::shared_ptr<BaseCardElement>> &new_body = container->GetItems();
                [self addTasksToConcurrentQueue: new_body];
                break;
            }
            // continue on search
            case CardElementType::Column:
            {
                std::shared_ptr<Column> colum = std::static_pointer_cast<Column>(elem);
                std::vector<std::shared_ptr<BaseCardElement>> &new_body = colum->GetItems();
                [self addTasksToConcurrentQueue: new_body];
                break;
            }
            // continue on search
            case CardElementType::ColumnSet:
            {
                std::shared_ptr<ColumnSet> columSet = std::static_pointer_cast<ColumnSet>(elem);
                std::vector<std::shared_ptr<Column>> &columns = columSet->GetColumns();
                // ColumnSet is vector of Column, instead of vector of BaseCardElement
                for(auto &colum : columns) { // update serial number that is used for generating unique key for image_map
                    [self addTasksToConcurrentQueue: colum->GetItems()];
                }
                break;
            }
            default:
            {
                /// no work is needed
                break;
            }
        }
    }
}

- (void)processTextConcurrently:(std::shared_ptr<BaseCardElement> const &)textElement
                    elementType:(CardElementType)elementType
                     textConfig:(TextConfig const &)textConfig
                      elementId:(NSString *)elementId
                           text:(std::string  const &)text
{
    std::shared_ptr<BaseCardElement> textElementForBlock = textElement;
    struct TextConfig textConfigForBlock = textConfig;
    std::string textForBlock = text;
    CardElementType elementTypeForBlock = elementType;
    /// dispatch to concurrent queue
    dispatch_group_async(_async_tasks_group, _global_queue,
        ^{
            NSString* parsedString = nil;
            if(CardElementType::TextBlock == elementTypeForBlock){
                std::shared_ptr<TextBlock> textBlockElement = std::dynamic_pointer_cast<TextBlock>(textElementForBlock);
                // MarkDownParser transforms text with MarkDown to a html string
                std::shared_ptr<MarkDownParser> markDownParser = std::make_shared<MarkDownParser>([ACOHostConfig getLocalizedDate:textBlockElement]);
                parsedString = [NSString stringWithCString:markDownParser->TransformToHtml().c_str() encoding:NSUTF8StringEncoding];
            } else {
                std::shared_ptr<MarkDownParser> markDownParser = std::make_shared<MarkDownParser>(textForBlock.c_str());
                parsedString = [NSString stringWithCString:markDownParser->TransformToHtml().c_str() encoding:NSUTF8StringEncoding];
            }

            // if correctly initialized, fonFamilyNames array is bigger than zero
            NSMutableString *fontFamilyName = [[NSMutableString alloc] initWithString:@"'"];
            [fontFamilyName appendString:[self->_hostConfig.fontFamilyNames componentsJoinedByString:@"', '"]];
            [fontFamilyName appendString:@"'"];

            // Font and text size are applied as CSS style by appending it to the html string
            parsedString = [parsedString stringByAppendingString:[NSString stringWithFormat:@"<style>body{font-family: %@; font-size:%dpx; font-weight: %d;}</style>",
                                                                  fontFamilyName,
                                                                  [self->_hostConfig getTextBlockTextSize:textConfigForBlock.size],
                                                                  [self->_hostConfig getTextBlockFontWeight:textConfigForBlock.weight]]];
            // Convert html string to NSMutableAttributedString, NSAttributedString knows how to apply html tags

            NSData *htmlData = [parsedString dataUsingEncoding:NSUTF16StringEncoding];
            NSDictionary *options = @{NSDocumentTypeDocumentAttribute: NSHTMLTextDocumentType};
            NSDictionary *data = @{@"html" : htmlData, @"options" : options};
            NSString *key = nil;

            if(CardElementType::TextBlock == elementTypeForBlock){
                std::shared_ptr<TextBlock> textBlockElement = std::dynamic_pointer_cast<TextBlock>(textElementForBlock);
                NSNumber *number = [NSNumber numberWithUnsignedLongLong:(unsigned long long)textBlockElement.get()];
                key = [number stringValue];
            } else {
                std::shared_ptr<FactSet> factSetElement = std::dynamic_pointer_cast<FactSet>(textElementForBlock);
                key = elementId;
            }
            dispatch_sync(self->_serial_text_queue, ^{self->_textMap[key] = data; });
         });
}

- (void)processImageConcurrently:(std::shared_ptr<Image> const &)imageElem
{
    /// generate a string key to uniquely identify Image
    std::shared_ptr<Image> imgElem = imageElem;
    // run image downloading and processing on global queue which is concurrent and different from main queue
    dispatch_group_async(_async_tasks_group, _global_queue,
        ^{
            NSString *urlStr = [NSString stringWithCString:imgElem->GetUrl().c_str()
                                                  encoding:[NSString defaultCStringEncoding]];
            // generate key for imageMap from image element's id
            NSURL *url = [NSURL URLWithString:urlStr];
            // download image
            UIImage *img = [UIImage imageWithData:[NSData dataWithContentsOfURL:url]];

            NSNumber *number = [NSNumber numberWithUnsignedLongLong:(unsigned long long)imgElem.get()];
            NSString *key = [number stringValue];
            dispatch_sync(self->_serial_queue, ^{self->_imageViewMap[key] = img; });
         }
    );
}

// add postfix to existing BaseCardElement ID to be used as key
-(void)tagBaseCardElement:(std::shared_ptr<BaseCardElement> const &)elem
{
    std::string serial_number_as_string = std::to_string(_serialNumber);
    // concat a newly generated key to a existing id, the key will be removed after use
    elem->SetId(elem->GetId() + "_" + serial_number_as_string);
    ++_serialNumber;
}

- (NSMutableDictionary *)getImageMap
{
    return _imageViewMap;
}
- (dispatch_queue_t)getSerialQueue
{
    return _serial_queue;
}

- (NSMutableDictionary *)getTextMap
{
    return _textMap;
}

- (NSMutableDictionary *)getActionsMap
{
    return _actionsMap;
}

- (ACOAdaptiveCard *)card
{
    return _adaptiveCard;
}

+ (void)setImageView:(UIImageView*)imageView inButton:(UIButton*)button withConfig:(ACOHostConfig *)config
{
    // Format the image so it fits in the button and is placed where it must be placed
    CGSize contentSize = [button.titleLabel intrinsicContentSize];
    double imageHeight = contentSize.height;
    CGSize originalImageSize = [imageView intrinsicContentSize];
    double scaleRatio = imageHeight / originalImageSize.height;
    double imageWidth = scaleRatio * originalImageSize.width;

    IconPlacement iconPlacement = [config getHostConfig]->actions.iconPlacement;
    if(iconPlacement == AdaptiveCards::IconPlacement::AboveTitle)
    {
        [imageView setFrame:CGRectMake( (button.frame.size.width - imageWidth) / 2, 5, imageWidth, imageHeight)];
        [button setTitleEdgeInsets:UIEdgeInsetsMake(imageHeight, 5, -imageHeight, 5)];
        [button setContentEdgeInsets:UIEdgeInsetsMake(5, 5, 5 + imageHeight, 5)];
    }
    else
    {
        int iconPadding = [config getHostConfig]->spacing.defaultSpacing;
        [button setTitleEdgeInsets:UIEdgeInsetsMake(5, (iconPadding + imageWidth), 5, 0)];
        double titleOriginX = button.titleLabel.frame.origin.x;
        [imageView setFrame:CGRectMake( titleOriginX - (iconPadding + imageWidth) / 2, 5, imageWidth, imageHeight)];
    }
    [button addSubview:imageView];
}
@end
